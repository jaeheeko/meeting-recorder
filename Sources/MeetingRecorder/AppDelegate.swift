import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case idle, starting, recording }
    private var state = State.idle { didSet { refresh() } }
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var recorder: Recorder?
    private var recordingStart = Date()
    private var timer: Timer?
    private var recent: [String] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        Paths.ensureDirs()
        Notifier.setup()
        if CommandLine.arguments.contains("--preview-editor") {   // 확인용: 포커스 없이 정리 프롬프트 편집 창을 뒤에 띄운다
            let c = Config.load()
            let u = c.organizePromptPath.isEmpty ? Paths.appSupport.appendingPathComponent("prompts/organize.md") : Config.expand(c.organizePromptPath)
            EditorWindows.shared.open(title: "정리 프롬프트", url: u, defaultText: nil, background: true)
        }
        if CommandLine.arguments.contains("--test-notify") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Pipeline.notify("MeetingRecorder", "알림 시험입니다.") }
        }
        recent = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: Paths.recentFile))) ?? []
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        let q = ProcessingQueue.shared
        q.onChange = { [weak self] in self?.refresh() }
        q.onFinish = { [weak self] job, result in self?.finished(job, result) }
        // 처리하지 못한 채 남은 세션은 다시 대기열에 넣어 이어서 처리한다. 실패·보존 세션은 알리기만 한다.
        let left = ProcessingQueue.scanLeftovers()
        if !left.resume.isEmpty {
            Pipeline.notify("MeetingRecorder", "처리하지 못한 회의 \(left.resume.count)건을 이어서 처리합니다")
            left.resume.forEach { q.enqueue(dir: $0) }
        }
        if left.preserved > 0 {
            Pipeline.notify("MeetingRecorder", "보존된 녹음 \(left.preserved)개가 남아 있음: \(Paths.sessions.path)")
        }
    }

    private func finished(_ job: ProcessingQueue.Job, _ result: Swift.Result<Pipeline.Result, Error>) {
        switch result {
        case .success(let res):
            let p = (res.saved ?? res.transcript).path
            addRecent(p)
            let extra = res.keptAudio.map { "\n" + $0 } ?? ""
            Pipeline.notify(res.saved != nil ? "회의록 저장됨" : "정리 실패", (res.saved != nil ? p : res.message) + extra, open: res.saved ?? res.transcript)
        case .failure(let error):
            Pipeline.notify("처리 실패", "\(error)")
        }
    }

    private func timeText(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    private var elapsedText: String {
        let s = Int(Date().timeIntervalSince(recordingStart))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 녹음 중에는 빨간 점 옆에 경과 시간을 짧게(고정폭 숫자) 붙인다. 그 밖의 상태는 아이콘만 쓴다.
    private func refresh() {
        guard let b = item.button else { return }
        b.attributedTitle = NSAttributedString(string: "")
        b.title = ""
        switch state {
        case .idle:
            // 녹음 중이 아닐 때만 처리 중 표시(모래시계)를 보인다.
            let n = ProcessingQueue.shared.count
            if n > 0 {
                b.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "처리 중")
                b.toolTip = "MeetingRecorder: 처리 중 \(n)건"
            } else {
                b.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "대기")
                b.toolTip = "MeetingRecorder: 대기"
            }
        case .starting:
            b.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "시작 중")
            b.toolTip = "MeetingRecorder: 시작 중"
        case .recording:
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "녹음 중")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            img?.isTemplate = false
            b.image = img
            b.imagePosition = .imageLeading
            b.attributedTitle = NSAttributedString(string: " \(elapsedText)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)])
            let n = ProcessingQueue.shared.count
            b.toolTip = "녹음 중 \(elapsedText)" + (n > 0 ? " · 처리 중 \(n)건" : "")
        }
    }

    @objc private func clicked() {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true { showMenu(); return }
        // 왼쪽 클릭 = 토글. (시작 중이면 메뉴만 보인다)
        if state == .starting { showMenu(); return }
        toggle()
    }

    private func showMenu() {
        let m = NSMenu()
        if state == .recording {
            let e = NSMenuItem(title: "녹음 중 \(elapsedText)", action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e)
        }
        let jobs = ProcessingQueue.shared.snapshot()
        if !jobs.isEmpty {
            let h = NSMenuItem(title: "처리 중 \(jobs.count)건", action: nil, keyEquivalent: ""); h.isEnabled = false; m.addItem(h)
            for j in jobs {
                let e = NSMenuItem(title: "  \(timeText(j.startedAt)) 시작: \(j.stage)", action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e)
            }
        }
        let t = NSMenuItem(title: state == .recording ? "녹음 종료" : "녹음 시작", action: state == .starting ? nil : #selector(toggle), keyEquivalent: "")
        t.target = self; m.addItem(t)
        m.addItem(.separator())
        if recent.isEmpty { let e = NSMenuItem(title: "최근 결과 없음", action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e) }
        for p in recent.prefix(5) {
            let i = NSMenuItem(title: (p as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.representedObject = p; i.target = self; m.addItem(i)
        }
        m.addItem(.separator())
        let st = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ","); st.target = self; m.addItem(st)
        let tr = NSMenuItem(title: "전사본 폴더 열기", action: #selector(openTranscripts), keyEquivalent: ""); tr.target = self; m.addItem(tr)
        let q = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"); q.target = self; m.addItem(q)
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .starting: break
        }
    }

    private func startRecording() {
        guard state == .idle else { return }
        state = .starting
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok else { self.state = .idle; Pipeline.notify("MeetingRecorder", "마이크 권한이 필요함. 시스템 설정 > 개인정보 보호 > 마이크"); return }
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
                let dir = Paths.sessions.appendingPathComponent(f.string(from: Date()))
                let r = Recorder(dir: dir)
                do { try r.start() } catch {
                    Pipeline.notify("MeetingRecorder", "녹음 시작 실패: \(error)")
                    _ = r.stop(); try? FileManager.default.removeItem(at: dir); self.state = .idle; return
                }
                self.recorder = r; self.recordingStart = Date(); self.state = .recording
                if Config.load().calendarEnabled { CalendarLookup.requestAccess() } // 사용자가 앞에 있을 때 권한을 받는다
            }
        }
    }

    /// 녹음을 멈추면 세션을 처리 대기열에 넣고 바로 대기로 돌아간다(다음 녹음을 시작할 수 있다).
    private func stopRecording() {
        guard let r = recorder else { return }
        let dir = r.dir
        _ = r.stop(); recorder = nil
        state = .idle
        ProcessingQueue.shared.enqueue(dir: dir)
    }

    private func addRecent(_ p: String) {
        recent.removeAll { $0 == p }; recent.insert(p, at: 0); recent = Array(recent.prefix(10))
        try? JSONEncoder().encode(recent).write(to: Paths.recentFile)
    }
    @objc private func openRecent(_ s: NSMenuItem) { if let p = s.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
    @objc private func openSettings() { SettingsView.show() }
    @objc private func openTranscripts() { NSWorkspace.shared.open(Paths.transcripts) }
    @objc private func quit() {
        let n = ProcessingQueue.shared.count
        if n > 0 || state == .recording {
            let a = NSAlert()
            a.messageText = n > 0 ? "처리 중인 회의가 \(n)건 있습니다" : "녹음 중입니다"
            a.informativeText = (n > 0 ? "종료하면 다음 실행 때 이어서 처리합니다." : "") + (state == .recording ? (n > 0 ? "\n" : "") + "녹음 중인 회의는 여기서 멈추고 다음 실행 때 처리합니다." : "")
            a.addButton(withTitle: "종료"); a.addButton(withTitle: "취소")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        if state == .recording, let r = recorder { _ = r.stop() } // session.json 이 남아 다음 실행 때 이어서 처리된다
        Organizer.terminateChildren()
        NSApp.terminate(nil)
    }
}

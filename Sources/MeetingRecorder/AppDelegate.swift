import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case idle, starting, recording, processing }
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
        // 전에 전사 실패로 남은 세션이 있으면 알린다.
        if let left = try? FileManager.default.contentsOfDirectory(atPath: Paths.sessions.path), !left.isEmpty {
            Pipeline.notify("MeetingRecorder", "처리되지 않은 녹음 \(left.count)개가 남아 있음: \(Paths.sessions.path)")
        }
    }

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
            b.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "대기")
            b.toolTip = "MeetingRecorder: 대기"
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
            b.toolTip = "녹음 중 \(elapsedText)"
        case .processing:
            b.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "처리 중")
            b.toolTip = "MeetingRecorder: 처리 중"
        }
    }

    @objc private func clicked() {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true { showMenu(); return }
        // 왼쪽 클릭 = 토글. (처리 중이면 메뉴만 보인다)
        if state == .processing || state == .starting { showMenu(); return }
        toggle()
    }

    private func showMenu() {
        let m = NSMenu()
        if state == .recording {
            let e = NSMenuItem(title: "녹음 중 \(elapsedText)", action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e)
        } else if state == .processing {
            let e = NSMenuItem(title: "처리 중", action: nil, keyEquivalent: ""); e.isEnabled = false; m.addItem(e)
        }
        let t = NSMenuItem(title: state == .recording ? "녹음 종료" : "녹음 시작", action: (state == .processing || state == .starting) ? nil : #selector(toggle), keyEquivalent: "")
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
        case .starting, .processing: break
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

    private func stopRecording() {
        guard let r = recorder else { return }
        let dir = r.dir
        _ = r.stop(); recorder = nil
        state = .processing
        Task {
            do {
                let res = try await Pipeline.process(sessionDir: dir)
                await MainActor.run {
                    let p = (res.saved ?? res.transcript).path
                    self.addRecent(p); self.state = .idle
                    let extra = res.keptAudio.map { "\n" + $0 } ?? ""
                    Pipeline.notify(res.saved != nil ? "회의록 저장됨" : "정리 실패", (res.saved != nil ? p : res.message) + extra, open: res.saved ?? res.transcript)
                }
            } catch {
                await MainActor.run { self.state = .idle; Pipeline.notify("처리 실패", "\(error)") }
            }
        }
    }

    private func addRecent(_ p: String) {
        recent.removeAll { $0 == p }; recent.insert(p, at: 0); recent = Array(recent.prefix(10))
        try? JSONEncoder().encode(recent).write(to: Paths.recentFile)
    }
    @objc private func openRecent(_ s: NSMenuItem) { if let p = s.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
    @objc private func openSettings() { SettingsView.show() }
    @objc private func openTranscripts() { NSWorkspace.shared.open(Paths.transcripts) }
    @objc private func quit() {
        if state == .recording { _ = recorder?.stop() } // 녹음 파일은 sessions 에 남는다
        NSApp.terminate(nil)
    }
}

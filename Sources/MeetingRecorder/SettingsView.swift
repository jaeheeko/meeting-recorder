import SwiftUI
import AppKit

/// 최소 설정 창. 나머지 고급 항목은 config.json 에서 직접 바꾼다.
struct SettingsView: View {
    @State private var cfg = Config.load()

    var body: some View {
        Form {
            Section("저장") {
                pathRow("저장 폴더", binding: $cfg.outputRoot)
                pathRow("작업 디렉터리", binding: $cfg.agentWorkingDir, placeholder: "(비우면 저장 폴더)")
            }
            Section("사용자") {
                TextField("내 이름", text: $cfg.userName)
            }
            Section("처리") {
                Toggle("전사 의미 교정", isOn: $cfg.correctionEnabled)
                Toggle("캘린더 참조", isOn: $cfg.calendarEnabled)
            }
            Section("편집") {
                HStack {
                    Button("정리 프롬프트 편집") { SettingsView.editPrompt(.organize) }
                    Button("교정 프롬프트 편집") { SettingsView.editPrompt(.correct) }
                    Button("용어 사전 편집") { SettingsView.editTerms() }
                }
                Button("config.json 열기") { cfg.save(); NSWorkspace.shared.open(Config.file) }
            }
            Text("저장 경로 패턴, 파일 이름, 모델 같은 고급 항목은 config.json 에서 바꾼다.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 480)
        .onChange(of: cfg.outputRoot) { _, _ in cfg.save() }
        .onChange(of: cfg.agentWorkingDir) { _, _ in cfg.save() }
        .onChange(of: cfg.userName) { _, _ in cfg.save() }
        .onChange(of: cfg.correctionEnabled) { _, _ in cfg.save() }
        .onChange(of: cfg.calendarEnabled) { _, _ in cfg.save() }
    }

    private func pathRow(_ title: String, binding: Binding<String>, placeholder: String = "") -> some View {
        HStack {
            TextField(title, text: binding, prompt: Text(placeholder))
            Button("선택…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                if p.runModal() == .OK, let u = p.url { binding.wrappedValue = u.path }
            }
        }
    }

    enum Kind { case organize, correct }

    /// 설정 경로가 비어 있으면 번들 기본본을 Application Support/prompts 로 복사해 설정에 연결한 뒤 기본 편집기로 연다.
    static func editPrompt(_ kind: Kind) {
        var c = Config.load()
        let (custom, bundled, name) = kind == .organize
            ? (c.organizePromptPath, "organize-prompt.md", "organize.md") : (c.correctPromptPath, "correct-prompt.md", "correct.md")
        var target = custom.isEmpty ? Paths.appSupport.appendingPathComponent("prompts/\(name)") : Config.expand(custom)
        if !FileManager.default.fileExists(atPath: target.path) {
            guard let src = Paths.resource(bundled) else { return }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: src, to: target)
        }
        target = target.standardizedFileURL
        if kind == .organize { c.organizePromptPath = target.path } else { c.correctPromptPath = target.path }
        c.save()
        NSWorkspace.shared.open(target)
    }

    static func editTerms() {
        let c = Config.load()
        let t = c.termsURL
        if !FileManager.default.fileExists(atPath: t.path) {
            try? FileManager.default.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
            let seed = Paths.resource("terms.example.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "# 한 줄에 용어 하나\n"
            try? seed.write(to: t, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(t)
    }

    static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "MeetingRecorder 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            window = w
        } else if let h = window?.contentViewController as? NSHostingController<SettingsView> {
            h.rootView = SettingsView() // 열 때마다 최신 config 를 읽는다
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

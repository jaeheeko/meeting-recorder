import SwiftUI
import AppKit

/// 최소 설정 창. 나머지 고급 항목은 config.json 에서 직접 바꾼다.
struct SettingsView: View {
    @State private var cfg = Config.load()
    @State private var nameDraft = Config.load().userName

    var body: some View {
        Form {
            Section("저장") {
                pathRow("저장 폴더", binding: $cfg.outputRoot)
                pathRow("작업 디렉터리", binding: $cfg.agentWorkingDir, placeholder: "(비우면 저장 폴더)")
            }
            Section("사용자") {
                // 이름은 Enter를 누르거나 창을 닫을 때만 저장한다(글자마다 저장하지 않는다).
                TextField("내 이름", text: $nameDraft).onSubmit { saveName() }
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
                Button("config.json 편집") { SettingsView.editConfig() }
            }
            Text("저장 경로 패턴, 파일 이름, 모델 같은 고급 항목은 config.json 에서 바꾼다. config.json 을 고친 뒤에는 이 창을 닫았다 다시 열면 반영된다.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 560, height: 560)
        .onChange(of: cfg.outputRoot) { _, v in Config.update { $0.outputRoot = v } }
        .onChange(of: cfg.agentWorkingDir) { _, v in Config.update { $0.agentWorkingDir = v } }
        .onDisappear { saveName() }
        .onChange(of: cfg.correctionEnabled) { _, v in Config.update { $0.correctionEnabled = v } }
        .onChange(of: cfg.calendarEnabled) { _, v in Config.update { $0.calendarEnabled = v } }
    }

    private func saveName() {
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { nameDraft = cfg.userName; return }
        if n != cfg.userName { cfg.userName = n; Config.update { $0.userName = n } }
    }

    private func pathRow(_ title: String, binding: Binding<String>, placeholder: String = "") -> some View {
        HStack {
            // 경로는 직접 타이핑하지 않고 "선택…"으로만 바꾼다(실수로 공백이 들어가 저장 위치가 깨지는 것을 막는다).
            Text(title)
            Spacer()
            Text(binding.wrappedValue.isEmpty ? placeholder : (binding.wrappedValue as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(binding.wrappedValue)
            Button("선택…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                if p.runModal() == .OK, let u = p.url { binding.wrappedValue = u.path }
            }
        }
    }

    enum Kind { case organize, correct }

    /// 설정 경로가 비어 있으면 번들 기본본을 Application Support/prompts 로 복사해 설정에 연결한 뒤 앱 안 편집 창으로 연다.
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
        let def = Paths.resource(bundled).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        EditorWindows.shared.open(title: kind == .organize ? "정리 프롬프트" : "교정 프롬프트", url: target, defaultText: def)
    }

    static func editConfig() {
        EditorWindows.shared.open(title: "config.json", url: Config.file) { text in
            guard let d = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) is [String: Any] else {
                return "JSON 형식이 올바르지 않아 저장하지 않았습니다."
            }
            return nil
        }
    }

    static func editTerms() {
        let c = Config.load()
        let t = c.termsURL
        if !FileManager.default.fileExists(atPath: t.path) {
            try? FileManager.default.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
            let seed = Paths.resource("terms.example.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "# 한 줄에 용어 하나\n"
            try? seed.write(to: t, atomically: true, encoding: .utf8)
        }
        let def = Paths.resource("terms.example.txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        EditorWindows.shared.open(title: "용어 사전", url: t, defaultText: def)
    }

    static var window: NSWindow?
    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 560, height: 560))
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
        // 창이 열리자마자 입력 칸에 포커스가 가지 않게 한다(다른 앱에서 치던 글자가 들어가는 사고 방지).
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
    }
}

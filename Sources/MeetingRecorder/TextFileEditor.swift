import SwiftUI
import AppKit

/// 앱 안에서 텍스트 파일(프롬프트, 용어 사전, config.json)을 고치는 창. "저장"을 눌러야 파일에 쓴다.
struct TextFileEditor: View {
    let url: URL
    let defaultText: String?
    let validate: ((String) -> String?)?   // 오류 메시지를 돌려주면 저장하지 않는다
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $state.text)
                .font(.system(size: 13, design: .monospaced))
                .padding(6)
            Divider()
            HStack(spacing: 10) {
                if let e = state.error {
                    Text(e).font(.footnote).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text(state.dirty ? "저장 안 됨" : "저장됨").font(.footnote).foregroundStyle(.secondary)
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.footnote).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        .help(url.path)
                }
                Spacer()
                if let d = defaultText {
                    Button("기본값으로") { state.text = d }.help("기본 내용으로 바꾼다. 저장을 눌러야 반영된다.")
                }
                Button("되돌리기") { state.text = state.saved; state.error = nil }.disabled(!state.dirty)
                Button("저장") { save() }.keyboardShortcut("s", modifiers: .command).disabled(!state.dirty)
            }
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func save() {
        if let v = validate, let msg = v(state.text) { state.error = msg; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try state.text.write(to: url, atomically: true, encoding: .utf8)
            state.saved = state.text
            state.error = nil
        } catch {
            state.error = "저장 실패: \(error.localizedDescription)"
        }
    }
}

final class EditorState: ObservableObject {
    @Published var text: String { didSet { if error != nil, text != oldValue { error = nil } } }
    @Published var saved: String
    @Published var error: String?
    var dirty: Bool { text != saved }
    init(_ t: String) { text = t; saved = t }
}

/// 파일마다 창 하나. 저장하지 않은 채 닫으려 하면 묻는다.
final class EditorWindows: NSObject, NSWindowDelegate {
    static let shared = EditorWindows()
    private var windows: [String: (NSWindow, EditorState)] = [:]

    func open(title: String, url: URL, defaultText: String? = nil, background: Bool = false, validate: ((String) -> String?)? = nil) {
        let key = url.standardizedFileURL.path
        if let (w, _) = windows[key] {
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (defaultText ?? "")
        let st = EditorState(text)
        let host = NSHostingController(rootView: TextFileEditor(url: url, defaultText: defaultText, validate: validate, state: st))
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 760, height: 620))
        w.isReleasedWhenClosed = false
        w.delegate = self
        windows[key] = (w, st)
        w.center()
        if background { w.orderBack(nil); return }   // 확인용: 키보드 포커스를 가져가지 않고 뒤에 띄운다
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let (_, st) = windows.values.first(where: { $0.0 === sender }), st.dirty else { return true }
        let a = NSAlert()
        a.messageText = "저장하지 않은 변경이 있습니다."
        a.informativeText = "닫으면 변경 내용이 사라집니다."
        a.addButton(withTitle: "닫기")
        a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        windows = windows.filter { $0.value.0 !== w }
    }
}

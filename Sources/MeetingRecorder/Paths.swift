import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let appSupport = home.appendingPathComponent("Library/Application Support/MeetingRecorder")
    static let transcripts = appSupport.appendingPathComponent("transcripts")
    static let sessions = appSupport.appendingPathComponent("sessions")
    static let recentFile = appSupport.appendingPathComponent("recent.json")
    /// 용어 사전 기본 위치(한 줄에 하나). config.termsPath 로 바꿀 수 있다.
    static let terms = appSupport.appendingPathComponent("terms.txt")

    static func ensureDirs() {
        for d in [transcripts, sessions] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// 번들 Resources → 소스 트리 Resources 순으로 찾는다.
    static func resource(_ name: String) -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: r.path) { return r }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name)")
        return FileManager.default.fileExists(atPath: src.path) ? src : nil
    }
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

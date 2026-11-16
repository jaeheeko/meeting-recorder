import Foundation

/// ~/Library/Application Support/MeetingRecorder/config.json. 없으면 기본값으로 만든다.
struct Config: Codable {
    /// 전사의 "나"가 누구인지. 프롬프트의 {{USER_NAME}}.
    var userName = "나"
    /// 정리 노트를 저장할 루트 폴더.
    var outputRoot = "~/Documents/Meeting Notes"
    /// claude 를 실행할 작업 디렉터리. 비우면 outputRoot. 규칙 파일(CLAUDE.md 등)이 있는 폴더(예: Obsidian vault)를 지정할 수 있다.
    var agentWorkingDir = ""
    /// AI가 고를 수 있는 저장 경로 패턴(outputRoot 기준 상대 경로). 각 `*`는 폴더·파일 이름 한 성분 안에서만 맞는다.
    var allowedPathPatterns = ["*.md"]
    /// 확신하지 못하거나 패턴을 벗어날 때 쓸 폴더(outputRoot 기준). 비우면 루트.
    var fallbackPath = ""
    /// 패턴의 와일드카드(`*`) 성분에 해당하는 상위 폴더가 실제로 있어야 하는지.
    var requireExistingParent = true
    var fileNameTemplate = "{{date}} {{title}}.md"
    /// 비우면 번들 기본 프롬프트.
    var organizePromptPath = ""
    var correctPromptPath = ""
    /// 용어 사전(한 줄에 하나). 비우면 Application Support/terms.txt.
    var termsPath = ""
    var correctionEnabled = true
    var calendarEnabled = true
    /// 비우면 PATH 와 ~/.local/bin 등에서 자동으로 찾는다.
    var claudePath = ""
    /// 비우면 claude 기본 모델.
    var model = ""
    /// 교정(전사 덩어리별)과 정리(요약·주제·저장 경로)에 쓸 모델. 비우면 model, 그것도 비우면 claude 기본 모델.
    var correctModel = "sonnet"
    var organizeModel = "opus"
    /// 기본 모델이 사용 한도에 걸리면 차례로 시도할 모델.
    var fallbackModels: [String] = ["opus", "sonnet"]
    /// true 면 오디오를 지우지 않는다. false 여도 실패 징후가 있으면 남긴다.
    var keepAudio = false
    /// claude 에 추가로 허용할 도구(기본 Read/Glob/Grep 외). 예: ["Bash(python3 -I scripts/search.py:*)"]
    var extraAllowedTools: [String] = []

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let x = Config()
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? x.userName
        outputRoot = try c.decodeIfPresent(String.self, forKey: .outputRoot) ?? x.outputRoot
        agentWorkingDir = try c.decodeIfPresent(String.self, forKey: .agentWorkingDir) ?? x.agentWorkingDir
        allowedPathPatterns = try c.decodeIfPresent([String].self, forKey: .allowedPathPatterns) ?? x.allowedPathPatterns
        fallbackPath = try c.decodeIfPresent(String.self, forKey: .fallbackPath) ?? x.fallbackPath
        requireExistingParent = try c.decodeIfPresent(Bool.self, forKey: .requireExistingParent) ?? x.requireExistingParent
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? x.fileNameTemplate
        organizePromptPath = try c.decodeIfPresent(String.self, forKey: .organizePromptPath) ?? x.organizePromptPath
        correctPromptPath = try c.decodeIfPresent(String.self, forKey: .correctPromptPath) ?? x.correctPromptPath
        termsPath = try c.decodeIfPresent(String.self, forKey: .termsPath) ?? x.termsPath
        correctionEnabled = try c.decodeIfPresent(Bool.self, forKey: .correctionEnabled) ?? x.correctionEnabled
        calendarEnabled = try c.decodeIfPresent(Bool.self, forKey: .calendarEnabled) ?? x.calendarEnabled
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? x.claudePath
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? x.model
        fallbackModels = try c.decodeIfPresent([String].self, forKey: .fallbackModels) ?? x.fallbackModels
        correctModel = try c.decodeIfPresent(String.self, forKey: .correctModel) ?? x.correctModel
        organizeModel = try c.decodeIfPresent(String.self, forKey: .organizeModel) ?? x.organizeModel
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? x.keepAudio
        extraAllowedTools = try c.decodeIfPresent([String].self, forKey: .extraAllowedTools) ?? x.extraAllowedTools
    }
    enum K: String, CodingKey {
        case userName, outputRoot, agentWorkingDir, allowedPathPatterns, fallbackPath, requireExistingParent, fileNameTemplate
        case organizePromptPath, correctPromptPath, termsPath, correctionEnabled, calendarEnabled, claudePath, model, correctModel, organizeModel, fallbackModels, keepAudio, extraAllowedTools
    }

    // MARK: 로드·저장

    /// 테스트용: --config 로 다른 파일을 가리킬 수 있다.
    static var fileOverride: URL?
    static var file: URL { fileOverride ?? Paths.appSupport.appendingPathComponent("config.json") }

    static func load() -> Config {
        let f = file
        if let d = try? Data(contentsOf: f) {
            if let c = try? JSONDecoder().decode(Config.self, from: d) { return c }
            log("config.json 을 읽지 못해 기본값을 씀: \(f.path)")
            return Config()
        }
        let c = Config(); c.save()
        return c
    }

    /// 파일의 최신 값을 읽어 한 항목만 바꿔 저장한다(앱 안에서 config.json 을 고친 내용을 덮어쓰지 않게).
    static func update(_ f: (inout Config) -> Void) { var c = Config.load(); f(&c); c.save() }

    func save() {
        try? FileManager.default.createDirectory(at: Config.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? e.encode(self) { try? d.write(to: Config.file) }
    }

    // MARK: 해석된 값

    static func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
    var outputRootURL: URL {
        let r = outputRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return Config.expand(r.isEmpty ? "~/Documents/Meeting Notes" : r)
    }
    var workingDirURL: URL {
        let w = agentWorkingDir.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = w.isEmpty ? outputRootURL : Config.expand(w)
        // 아직 없는 폴더(첫 실행 전 기본 경로)는 claude 실행 위치로 못 쓰니 앱 폴더로 대신한다.
        return FileManager.default.fileExists(atPath: u.path) ? u : Paths.appSupport
    }
    var termsURL: URL { termsPath.isEmpty ? Paths.terms : Config.expand(termsPath) }
    /// 표시용 이름. 기본값 "나"는 이름이 아니므로 풀어서 쓴다.
    var userDisplayName: String { (userName.isEmpty || userName == "나") ? "녹음한 사용자" : userName }

    var claudeURL: String {
        if !claudePath.isEmpty { return (claudePath as NSString).expandingTildeInPath }
        if let e = ProcessInfo.processInfo.environment["MR_CLAUDE"], !e.isEmpty { return e }
        let fm = FileManager.default
        let cands = ["\(Paths.home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                     "\(Paths.home.path)/.claude/local/claude", "\(Paths.home.path)/.npm-global/bin/claude", "\(Paths.home.path)/.bun/bin/claude"]
        for c in cands where fm.isExecutableFile(atPath: c) { return c }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let c = "\(dir)/claude"; if fm.isExecutableFile(atPath: c) { return c }
        }
        return cands[0]
    }

    /// 프롬프트 파일: 설정 경로가 있고 존재하면 그것, 아니면 번들 기본본.
    func promptURL(custom: String, bundled: String) -> URL? {
        if !custom.isEmpty {
            let u = Config.expand(custom)
            if FileManager.default.fileExists(atPath: u.path) { return u }
            log("프롬프트 파일이 없어 기본본을 씀: \(u.path)")
        }
        return Paths.resource(bundled)
    }
}

/// AI가 고른 저장 경로를 설정의 패턴으로 검증한다.
struct PathPolicy {
    var patterns: [String]
    var fallback: String
    var requireExistingParent: Bool
    var root: URL

    static func parts(_ s: String) -> [String] {
        s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
    static func isWild(_ s: String) -> Bool { s.contains("*") || s.contains("?") || s.contains("[") }

    /// 돌려주는 경로는 항상 root 기준 상대 경로. 통과하지 못하면 fallback 폴더 + 파일 이름.
    func resolve(path raw: String, confident: Bool, defaultFileName: String) -> (path: String, note: String?) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`\" \n"))
        let comps = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var file = (comps.last ?? "").replacingOccurrences(of: ":", with: "-")
        if file.isEmpty || file == "." || file == ".." { file = defaultFileName }
        if !file.hasSuffix(".md") { file += ".md" }
        let fbParts = Self.parts(fallback)
        let fallbackPath = (fbParts + [file]).joined(separator: "/")

        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !comps.contains(".."), !comps.contains("."), !comps.contains(""),
              !comps.contains(where: { $0.hasPrefix(".") }) else {
            return (fallbackPath, "경로가 안전하지 않아 기본 폴더로 돌림")
        }
        for pat in patterns {
            let pc = Self.parts(pat)
            guard pc.count == comps.count,
                  zip(pc, comps).allSatisfy({ fnmatch($0, $1, 0) == 0 }) else { continue }
            let normalized = Array(comps.dropLast()) + [file]
            if requireExistingParent {
                var prefix = root
                for i in 0..<(pc.count - 1) {
                    prefix.appendPathComponent(comps[i])
                    var isDir: ObjCBool = false
                    if Self.isWild(pc[i]), !(FileManager.default.fileExists(atPath: prefix.path, isDirectory: &isDir) && isDir.boolValue) {
                        return (fallbackPath, "상위 폴더(\(comps[0...i].joined(separator: "/")))가 없어 기본 폴더로 돌림")
                    }
                }
            }
            let isFallbackDir = Array(comps.dropLast()) == fbParts
            if !confident && !isFallbackDir { return (fallbackPath, "확신하지 못해 기본 폴더로 돌림") }
            return (normalized.joined(separator: "/"), nil)
        }
        return (fallbackPath, "허용되지 않은 경로(\(trimmed))라 기본 폴더로 돌림")
    }
}

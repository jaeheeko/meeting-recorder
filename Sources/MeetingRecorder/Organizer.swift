import Foundation

struct OrganizePlan {
    var relPath: String
    var confidence: String
    var reason: String
    var body: String          // 정리 본문(원문 제외)
    var fullDocument: String  // 정리 본문 + 전사(AI 교정본)
    var report: Corrector.Report? = nil
}

enum Organizer {
    struct E: Error, CustomStringConvertible { let description: String }

    /// transcripts/*.md 를 읽어 (녹음 시작 문자열, 원문 줄들)로 나눈다.
    /// transcripts/*.md 를 읽어 (녹음 시작, 트랙 상태, 원문 줄들)로 나눈다. 헤더는 첫 빈 줄까지다.
    static func readTranscript(_ url: URL) throws -> (started: String, tracks: String, calendar: [CalEvent], raw: String) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let split = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? lines.count
        let head = lines[..<min(split, lines.count)]
        var started = "", tracks = ""; var cal: [CalEvent] = []
        for l in head {
            if l.hasPrefix("녹음 시작:") { started = l.replacingOccurrences(of: "녹음 시작:", with: "").trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("캘린더:") { cal = CalendarLookup.parseHeader(String(l.dropFirst("캘린더:".count)).trimmingCharacters(in: .whitespaces)) }
            if l.hasPrefix("상대 트랙:") { tracks = l.replacingOccurrences(of: "상대 트랙:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        let raw = lines[min(split, lines.count)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if started.isEmpty {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            started = f.string(from: Date())
        }
        return (started, tracks, cal, raw)
    }

    static func allowedPathsText(_ c: Config) -> String {
        c.allowedPathPatterns.map { "- `\($0)`" }.joined(separator: "\n")
    }

    static func prompt(started: String, tracks: String, calendar: String, raw: String, cfg: Config) throws -> String {
        guard let url = cfg.promptURL(custom: cfg.organizePromptPath, bundled: "organize-prompt.md"),
              let t = try? String(contentsOf: url, encoding: .utf8) else { throw E(description: "정리 프롬프트를 찾지 못했다") }
        let fb = cfg.fallbackPath.isEmpty ? "(저장 루트 바로 아래)" : "`\(cfg.fallbackPath)/`"
        return t
            .replacingOccurrences(of: "{{USER_NAME}}", with: cfg.userDisplayName)
            .replacingOccurrences(of: "{{ALLOWED_PATHS}}", with: allowedPathsText(cfg))
            .replacingOccurrences(of: "{{FALLBACK_PATH}}", with: fb)
            .replacingOccurrences(of: "{{FILE_NAME_RULE}}", with: "`\(cfg.fileNameTemplate)` ({{date}}는 녹음 시작 날짜 YYYY-MM-DD, {{title}}은 짧은 회의 주제)")
            .replacingOccurrences(of: "{{CALENDAR}}", with: calendar)
            .replacingOccurrences(of: "{{STARTED}}", with: started)
            .replacingOccurrences(of: "{{TRACKS}}", with: tracks.isEmpty ? "알 수 없음" : tracks)
            .replacingOccurrences(of: "{{TRANSCRIPT}}", with: raw)
    }

    private static var children: [Process] = []
    private static let childLock = NSLock()
    /// 앱 종료 때 돌고 있는 claude 를 정리한다.
    static func terminateChildren() {
        childLock.lock(); let c = children; childLock.unlock()
        for p in c where p.isRunning { p.terminate() }
    }

    static func runClaude(prompt: String, cwd: URL? = nil, tools: [String]? = nil, timeout: TimeInterval = 900, cfg: Config = Config.load()) throws -> String {
        let p = Process()
        p.qualityOfService = .utility   // 녹음이 끊기지 않게 처리 쪽은 낮은 우선순위로
        p.executableURL = URL(fileURLWithPath: cfg.claudeURL)
        var args = ["-p", "--no-session-persistence", "--permission-mode", "dontAsk"]
        if let tools {  // 도구 없는 교정용: 내장 도구를 모두 끈다
            args += ["--tools", tools.joined(separator: ",")]
        } else {
            args += ["--allowedTools", "Read", "Glob", "Grep"] + cfg.extraAllowedTools + [
                     "--disallowedTools", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch"]
        }
        let model = cfg.model.isEmpty ? (ProcessInfo.processInfo.environment["MR_MODEL"] ?? "") : cfg.model
        if !model.isEmpty { args += ["--model", model] }
        p.arguments = args
        p.currentDirectoryURL = cwd ?? cfg.workingDirURL
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Paths.home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        signal(SIGPIPE, SIG_IGN)
        try p.run()
        childLock.lock(); children.append(p); childLock.unlock()
        defer { childLock.lock(); children.removeAll { $0 === p }; childLock.unlock() }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        do { try inPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8)) } catch { log("stdin 쓰기 실패(claude가 먼저 끝남?): \(error)") }
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit(); killer.cancel()
        if g.wait(timeout: .now() + 10) == .timedOut {
            try? outPipe.fileHandleForReading.close(); try? errPipe.fileHandleForReading.close()
        }
        if timedOut { throw E(description: "claude가 \(Int(timeout))초 안에 끝나지 않아 종료함") }
        let out = String(decoding: outData, as: UTF8.self)
        if p.terminationStatus != 0 {
            throw E(description: "claude 종료 코드 \(p.terminationStatus): \(String(decoding: errData, as: UTF8.self).prefix(400)) \(out.prefix(400))")
        }
        return out
    }

    static func parse(_ out: String) throws -> (path: String, conf: String, reason: String, body: String) {
        func section(_ name: String, next: String?) -> String? {
            guard let r = out.range(of: "===\(name)===") else { return nil }
            var rest = String(out[r.upperBound...])
            if let next, let n = rest.range(of: "===\(next)===") { rest = String(rest[..<n.lowerBound]) }
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let path = section("PATH", next: "CONFIDENCE")?.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), let body = section("BODY", next: nil), !body.isEmpty else {
            throw E(description: "claude 답변 형식을 해석하지 못했다: \(out.prefix(300))")
        }
        var b = body
        if b.hasPrefix("```") { // 앞뒤 코드펜스를 벗긴다
            b = b.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            b = b.trimmingCharacters(in: .whitespacesAndNewlines)
            if b.hasSuffix("```") { b = String(b.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return (path, section("CONFIDENCE", next: "REASON") ?? "", section("REASON", next: "BODY") ?? "", b)
    }

    static func sanitize(path raw: String, confidence: String, started: String, cfg: Config) -> (path: String, note: String?) {
        let policy = PathPolicy(patterns: cfg.allowedPathPatterns, fallback: cfg.fallbackPath,
                                requireExistingParent: cfg.requireExistingParent, root: cfg.outputRootURL)
        return policy.resolve(path: raw, confident: confidence.hasPrefix("확실"), defaultFileName: "\(started.prefix(10)) 회의.md")
    }

    static func plan(transcript: URL, calendar override: [CalEvent]? = nil, correct: Bool = true, progress: ((String) -> Void)? = nil) throws -> OrganizePlan {
        let (started, tracks, headerCal, raw) = try readTranscript(transcript)
        guard !raw.isEmpty else { throw E(description: "전사문이 비어 있다") }
        let cfg = Config.load()
        let cal = CalendarLookup.render(override ?? headerCal)
        var corrected = raw
        var report: Corrector.Report? = nil
        if correct && cfg.correctionEnabled {
            progress?("교정")
            let r = Corrector.correct(raw: raw, tracks: tracks, calendar: cal)
            corrected = r.text; report = r.report
        }
        progress?("정리")
        let out = try runClaude(prompt: try prompt(started: started, tracks: tracks, calendar: cal, raw: corrected, cfg: cfg), cfg: cfg)
        let r = try parse(out)
        let (path, note) = sanitize(path: r.path, confidence: r.conf, started: started, cfg: cfg)
        let body = insertOriginalLink(r.body, path: transcript.path)
        let doc = body + "\n\n## 전사 (AI 교정본)\n\n" + corrected + "\n"
        return OrganizePlan(relPath: path, confidence: r.conf, reason: r.reason + (note.map { " [앱: \($0)]" } ?? ""),
                            body: body, fullDocument: doc, report: report)
    }

    /// frontmatter 바로 아래에 교정 전 원문 파일 경로를 한 줄 적는다.
    static func insertOriginalLink(_ body: String, path: String) -> String {
        let line = "원문(교정 전) 전사: `\(path)`"
        let lines = body.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var l = lines; l.insert(contentsOf: ["", line], at: end + 1)
            return l.joined(separator: "\n")
        }
        return line + "\n\n" + body
    }

    /// 저장 폴더에 새 파일로 쓴다(덮어쓰지 않는다. 있으면 " (2)"). 쓴 파일의 절대 경로를 돌려준다.
    static func write(_ plan: OrganizePlan) throws -> URL {
        let fm = FileManager.default
        let root = Config.load().outputRootURL
        var url = root.appendingPathComponent(plan.relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            let base = (plan.relPath as NSString).deletingPathExtension
            url = root.appendingPathComponent("\(base) (\(n)).md"); n += 1
        }
        try plan.fullDocument.write(to: url, atomically: false, encoding: .utf8)
        return url
    }
}

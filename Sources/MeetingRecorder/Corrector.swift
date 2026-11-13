import Foundation

/// 전사 원문을 덩어리로 나눠 `claude -p` 로 의미 교정한다. 덩어리마다 검증하고, 실패하면 원문을 넣는다.
enum Corrector {
    struct Report { var chunks: Int; var ok: Int; var failed: [String]; var seconds: Double }

    static let failMarker = "(이 구간은 교정 실패, 원문)"

    static func stampOf(_ line: String) -> String? {
        guard line.hasPrefix("["), let r = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<r])
    }
    static func seconds(_ stamp: String) -> Int {
        stamp.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
    static func letters(_ s: String) -> Int { s.filter { $0.isLetter || $0.isNumber }.count }

    /// 타임스탬프 줄 경계로 나눈다: 10분 이상이거나 글자가 maxChars 를 넘으면 새 덩어리.
    static func chunk(_ raw: String, maxChars: Int = 7000, maxSeconds: Int = 600) -> [[String]] {
        var chunks: [[String]] = [], cur: [String] = []
        var curChars = 0, startSec = 0
        for line in raw.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let t = stampOf(line).map(seconds) ?? startSec
            if !cur.isEmpty && (curChars + line.count > maxChars || t - startSec >= maxSeconds) {
                chunks.append(cur); cur = []; curChars = 0
            }
            if cur.isEmpty { startSec = t }
            cur.append(line); curChars += line.count
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }

    /// 검증: 타임스탬프 순서(연속 중복 제거)가 같고, 글자 수가 60%~130%.
    static func validate(input: [String], output: [String]) -> String? {
        func stamps(_ ls: [String]) -> [String] {
            var r: [String] = []
            for l in ls { if let s = stampOf(l), r.last != s { r.append(s) } }
            return r
        }
        if output.contains(where: { stampOf($0) == nil }) { return "타임스탬프 없는 줄 있음" }
        let a = stamps(input), b = stamps(output)
        if a != b { return "타임스탬프 불일치(입력 \(a.count)개, 출력 \(b.count)개)" }
        let li = letters(input.joined()), lo = letters(output.joined())
        let ratio = Double(lo) / Double(max(li, 1))
        if ratio < 0.6 { return String(format: "글자 수 %.0f%%로 지나치게 줄음", ratio * 100) }
        if ratio > 1.3 { return String(format: "글자 수 %.0f%%로 지나치게 늘음", ratio * 100) }
        return nil
    }

    static func cleanOutput(_ out: String) -> [String] {
        var lines = out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") }
        return lines
    }

    static func correct(raw: String, tracks: String, calendar: String, parallel: Int = 3) -> (text: String, report: Report) {
        let t0 = Date()
        let chunks = chunk(raw)
        let cfg = Config.load()
        let terms = Transcriber.loadTerms()
        let template: String = {
            let u = cfg.promptURL(custom: cfg.correctPromptPath, bundled: "correct-prompt.md")
            return (u.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
        }()
        var results = [[String]?](repeating: nil, count: chunks.count)
        var failures: [String?] = [String?](repeating: nil, count: chunks.count)
        if template.isEmpty {
            return (raw, Report(chunks: chunks.count, ok: 0, failed: ["correct-prompt.md 없음"], seconds: 0))
        }
        let lock = NSLock(), sem = DispatchSemaphore(value: parallel), g = DispatchGroup()
        for (i, c) in chunks.enumerated() {
            g.enter(); sem.wait()
            DispatchQueue.global(qos: .utility).async {
                defer { sem.signal(); g.leave() }
                let prompt = template
                    .replacingOccurrences(of: "{{USER_NAME}}", with: cfg.userDisplayName)
                    .replacingOccurrences(of: "{{TRACKS}}", with: tracks.isEmpty ? "알 수 없음" : tracks)
                    .replacingOccurrences(of: "{{CALENDAR}}", with: calendar)
                    .replacingOccurrences(of: "{{TERMS}}", with: terms.isEmpty ? "(없음)" : terms.joined(separator: ", "))
                    .replacingOccurrences(of: "{{CHUNK}}", with: c.joined(separator: "\n"))
                var reason: String? = nil
                var good: [String]? = nil
                for attempt in 1...2 { // 실패하면 한 번 더 시도
                    do {
                        let out = try Organizer.runClaude(prompt: prompt, cwd: Paths.appSupport, tools: [], timeout: 600, cfg: cfg)
                        let lines = cleanOutput(out)
                        if let why = validate(input: c, output: lines) { reason = "시도\(attempt): \(why)" } else { good = lines; reason = nil; break }
                    } catch { reason = "시도\(attempt): \(error)" }
                }
                lock.lock(); results[i] = good; failures[i] = good == nil ? "덩어리 \(i + 1): \(reason ?? "")" : nil; lock.unlock()
            }
        }
        g.wait()
        var text: [String] = []
        for (i, c) in chunks.enumerated() {
            if let r = results[i] { text += r } else { text.append(failMarker); text += c }
        }
        let failed = failures.compactMap { $0 }
        return (text.joined(separator: "\n"), Report(chunks: chunks.count, ok: chunks.count - failed.count, failed: failed, seconds: Date().timeIntervalSince(t0)))
    }
}

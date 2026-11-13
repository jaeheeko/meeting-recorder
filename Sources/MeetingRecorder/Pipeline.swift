import Foundation

enum Pipeline {
    static let silentThreshold: Float = 0.003

    static func meaningfulCount(_ s: String) -> Int {
        // 화자 표시와 타임스탬프는 빼고 글자·숫자만 센다.
        s.components(separatedBy: "\n").map { line -> String in
            if let r = line.range(of: ": ") , line.hasPrefix("[") { return String(line[r.upperBound...]) }
            return line
        }.joined().filter { $0.isLetter || $0.isNumber }.count
    }

    /// 오디오를 남길 이유. 비어 있으면 삭제한다.
    static func retentionReasons(_ info: SessionInfo) -> [String] {
        var r: [String] = []
        if info.meFile == nil { r.append("내 트랙 없음") }
        else if let p = info.mePeak, p < silentThreshold { r.append("내 트랙 무음") }
        if !info.warnings.isEmpty { r.append("오류 경고 있음") }
        return r
    }
    struct Result { var transcript: URL; var saved: URL?; var message: String; var keptAudio: String? = nil }

    static func notify(_ title: String, _ body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
        try? p.run()
    }

    static func header(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d)
    }

    /// 두 트랙을 전사해 합친 원문을 만든다.
    static func transcribeTracks(me: URL?, other: URL?, meOffset: Double, otherOffset: Double) async throws -> String {
        var segs: [Segment] = []
        if let me { segs += try await Transcriber.transcribe(url: me, speaker: "나", offset: meOffset) }
        if let other { segs += try await Transcriber.transcribe(url: other, speaker: "상대", offset: otherOffset) }
        return Merge.render(segs)
    }

    /// 녹음 세션 폴더를 처리한다: 전사 → transcripts 저장 → (성공 시) 오디오 삭제 → 정리 → 노트 저장.
    static func process(sessionDir: URL) async throws -> Result {
        Paths.ensureDirs()
        let data = try Data(contentsOf: sessionDir.appendingPathComponent("session.json"))
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .deferredToDate
        let info = try dec.decode(SessionInfo.self, from: data)
        guard info.meFile != nil || info.otherFile != nil else { throw Organizer.E(description: "녹음된 오디오가 없다") }
        let raw: String
        do {
            raw = try await transcribeTracks(
                me: info.meFile.map { sessionDir.appendingPathComponent($0) },
                other: info.otherFile.map { sessionDir.appendingPathComponent($0) },
                meOffset: info.meOffset, otherOffset: info.otherOffset)
        } catch { throw Organizer.E(description: "전사 실패(오디오는 \(sessionDir.path) 에 남김): \(error)") }
        // 글자·숫자가 5개 미만이면 사실상 빈 전사다(예: "."만 나온 경우). 노트로 저장하지 않고 알림만 띄운다.
        guard meaningfulCount(raw) >= 5 else { throw Organizer.E(description: "전사 결과가 사실상 비었다(음성 없음?). 노트로는 저장하지 않음. 오디오는 \(sessionDir.path) 에 남김") }

        let fn = DateFormatter(); fn.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = fn.string(from: info.startedAt)
        let warn = info.warnings.isEmpty ? "" : "\n경고: " + info.warnings.joined(separator: "; ")
        let otherSilent = info.otherSilent ?? (info.otherFile == nil || (info.otherPeak ?? 1) < silentThreshold)
        let tracks = otherSilent ? "\n상대 트랙: 무음(대면 회의)" : "\n상대 트랙: 소리 있음"
        let content = "# 회의 전사 원문\n녹음 시작: \(header(info.startedAt))\(tracks)\(CalendarLookup.headerLine(info.calendar ?? []))\(warn)\n\n" + raw + "\n"
        // 덮어쓰지 않는다. 같은 이름이 있으면 " (2)".
        var tURL = Paths.transcripts.appendingPathComponent("\(base).md")
        var n = 2
        while true {
            do { try content.data(using: .utf8)!.write(to: tURL, options: .withoutOverwriting); break }
            catch let e as CocoaError where e.code == .fileWriteFileExists {
                tURL = Paths.transcripts.appendingPathComponent("\(base) (\(n)).md"); n += 1
            }
        }
        // 전사본을 다시 읽어 확인한 뒤에만 오디오를 지운다. 이상 징후가 있으면 남기고 알린다.
        guard let back = try? String(contentsOf: tURL, encoding: .utf8), back == content else {
            throw Organizer.E(description: "전사본 저장 확인 실패. 오디오는 \(sessionDir.path) 에 남김")
        }
        // 보존 기준: 마이크 트랙이 없거나 무음, 실제 오류 경고. 상대 트랙만 무음이면 대면 회의로 보고 정상 처리한다.
        let reasons = retentionReasons(info)
        var kept: String? = nil
        if reasons.isEmpty && !Config.load().keepAudio { try? FileManager.default.removeItem(at: sessionDir) }
        else if reasons.isEmpty { kept = "오디오를 보관함(설정 keepAudio): \(sessionDir.path)" }
        else { kept = "오디오를 남김(\(reasons.joined(separator: ", "))): \(sessionDir.path)" }

        do {
            let plan = try Organizer.plan(transcript: tURL)
            let saved = try Organizer.write(plan)
            return Result(transcript: tURL, saved: saved, message: saved.path, keptAudio: kept)
        } catch {
            return Result(transcript: tURL, saved: nil, message: "정리 실패, 전사본은 \(tURL.path) 에 저장됨: \(error)", keptAudio: kept)
        }
    }
}

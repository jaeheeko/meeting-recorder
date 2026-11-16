import Foundation
import FluidAudio

/// 목소리로 화자를 나눈다(FluidAudio 오프라인 pyannote 파이프라인, Core ML/ANE).
/// 모델은 처음 쓸 때 ~/Library/Application Support/FluidAudio/Models 에 내려받는다.
enum Diarization {
    struct Turn { var start: Double; var end: Double; var speaker: String }
    struct Output { var turns: [Turn]; var centroids: [String: [Float]]; var seconds: Double }

    /// 모델을 미리 받아 둔다(설정에서 켤 때). 오프라인이면 throw.
    static func prefetch() async throws {
        let m = OfflineDiarizerManager()
        try await m.prepareModels()
    }

    static func run(url: URL) async throws -> Output {
        let t0 = Date()
        let m = OfflineDiarizerManager()
        try await m.prepareModels()
        let res = try await m.process(url)
        let turns = res.segments.map { Turn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId) }
        var cent = res.speakerDatabase ?? [:]
        if cent.isEmpty { // 센트로이드가 없으면 구간 임베딩의 평균으로 대신한다
            var sums: [String: ([Float], Int)] = [:]
            for s in res.segments where !s.embedding.isEmpty {
                var (v, n) = sums[s.speakerId] ?? ([Float](repeating: 0, count: s.embedding.count), 0)
                for i in 0..<v.count { v[i] += s.embedding[i] }
                sums[s.speakerId] = (v, n + 1)
            }
            for (k, (v, n)) in sums { cent[k] = v.map { $0 / Float(max(n, 1)) } }
        }
        return Output(turns: turns, centroids: cent, seconds: Date().timeIntervalSince(t0))
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    // MARK: 내 목소리 프로필

    struct VoiceProfile: Codable { var embedding: [Float]; var createdAt: Date; var seconds: Double }
    static var profileURL: URL { Paths.appSupport.appendingPathComponent("voice-profile.json") }
    static func loadProfile() -> VoiceProfile? {
        guard let d = try? Data(contentsOf: profileURL) else { return nil }
        return try? JSONDecoder().decode(VoiceProfile.self, from: d)
    }
    /// 이 거리(코사인 거리) 이하인 클러스터만 "나"로 본다.
    static let meThreshold: Float = 0.5

    /// 한 사람만 말한 녹음에서 가장 길게 말한 클러스터의 센트로이드를 프로필로 저장한다.
    static func enroll(from url: URL) async throws -> VoiceProfile {
        let out = try await run(url: url)
        var dur: [String: Double] = [:]
        for t in out.turns { dur[t.speaker, default: 0] += t.end - t.start }
        guard let best = dur.max(by: { $0.value < $1.value }), best.value >= 5, let emb = out.centroids[best.key] else {
            throw NSError(domain: "MR", code: 3, userInfo: [NSLocalizedDescriptionKey: "말소리가 5초 이상 잡히지 않았다"])
        }
        let p = VoiceProfile(embedding: emb, createdAt: Date(), seconds: best.value)
        try JSONEncoder().encode(p).write(to: profileURL)
        return p
    }

    // MARK: 전사 구간에 화자 붙이기

    /// 클러스터 → 표시 이름. 나로 식별된 클러스터는 "나", 나머지는 처음 등장한 순서대로 "화자 A", "화자 B"…
    static func labels(out: Output, profile: VoiceProfile?) -> (map: [String: String], meId: String?, meDistance: Float?) {
        var meId: String? = nil, meDist: Float? = nil
        if let profile {
            for (id, c) in out.centroids {
                let d = cosineDistance(profile.embedding, c)
                if d <= meThreshold, d < (meDist ?? .infinity) { meId = id; meDist = d }
            }
        }
        var map: [String: String] = [:]
        if let meId { map[meId] = "나" }
        var n = 0
        for t in out.turns.sorted(by: { $0.start < $1.start }) where map[t.speaker] == nil {
            map[t.speaker] = "화자 " + String(UnicodeScalar(UInt8(65 + min(n, 25)))); n += 1
        }
        return (map, meId, meDist)
    }

    static func speaker(at t: Double, turns: [Turn]) -> String? {
        if let hit = turns.first(where: { $0.start <= t && t <= $0.end }) { return hit.speaker }
        // 구간 사이의 짧은 틈은 가장 가까운 구간(1초 이내)에 붙인다
        let near = turns.min(by: { min(abs($0.start - t), abs($0.end - t)) < min(abs($1.start - t), abs($1.end - t)) })
        if let near, min(abs(near.start - t), abs(near.end - t)) <= 1.0 { return near.speaker }
        return nil
    }

    /// 전사 구간(단어 시각이 있으면 단어 단위)을 화자별로 나눠 라벨을 바꾼다. 못 나누면 겹침이 가장 큰 화자로 붙인다.
    static func apply(_ segs: [Segment], out: Output, offset: Double, fallbackLabel: String, profile: VoiceProfile?) -> (segs: [Segment], note: String) {
        let (map, meId, meDist) = labels(out: out, profile: profile)
        let turns = out.turns.map { Turn(start: $0.start + offset, end: $0.end + offset, speaker: $0.speaker) }
        let clusters = Set(out.turns.map { $0.speaker }).count
        func label(_ id: String?) -> String { id.flatMap { map[$0] } ?? fallbackLabel }
        var result: [Segment] = []
        for s in segs {
            if !s.words.isEmpty {
                var pieces: [(String, [Word])] = []
                var lastId: String? = nil
                for w in s.words {
                    let id = speaker(at: (w.start + w.end) / 2, turns: turns) ?? lastId
                    let key = id ?? "?"
                    if pieces.last?.0 == key { pieces[pieces.count - 1].1.append(w) } else { pieces.append((key, [w])) }
                    lastId = id ?? lastId
                }
                // 한 단어짜리 조각이 같은 화자 사이에 끼면 앞뒤에 흡수한다(경계 흔들림 제거)
                var i = 1
                while i + 1 < pieces.count {
                    if pieces[i].1.count == 1, pieces[i - 1].0 == pieces[i + 1].0 {
                        pieces[i - 1].1 += pieces[i].1 + pieces[i + 1].1
                        pieces.removeSubrange(i...(i + 1))
                    } else { i += 1 }
                }
                for (id, ws) in pieces {
                    let text = ws.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { continue }
                    result.append(Segment(start: ws.first!.start, end: ws.last!.end, speaker: label(id == "?" ? nil : id), text: text, words: ws))
                }
            } else {
                var overlap: [String: Double] = [:]
                for t in turns { overlap[t.speaker, default: 0] += max(0, min(t.end, s.end) - max(t.start, s.start)) }
                let id = overlap.max(by: { $0.value < $1.value }).flatMap { $0.value > 0 ? $0.key : nil }
                var c = s; c.speaker = label(id); result.append(c)
            }
        }
        // 클러스터가 하나뿐이고 식별 결과가 없으면 라벨을 만들지 않고 기존 표시를 쓴다.
        if clusters <= 1 && meId == nil {
            return (segs, "클러스터 \(clusters)명 → 분리 안 함(\(String(format: "%.0f", out.seconds))초)")
        }
        let meText = profile == nil ? "내 목소리 미등록" : (meId != nil ? "나 식별됨(거리 \(String(format: "%.2f", meDist ?? 0)))" : "나 식별 안 됨")
        return (result, "적용: 화자 \(clusters)명, \(meText), \(String(format: "%.0f", out.seconds))초")
    }
}

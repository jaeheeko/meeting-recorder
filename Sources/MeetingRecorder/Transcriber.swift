import Foundation
import Speech
import AVFoundation
import CoreMedia

struct Segment {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

enum Transcriber {
    static func loadTerms() -> [String] {
        guard let s = try? String(contentsOf: Config.load().termsURL, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 파일 하나를 ko_KR 로 전사한다. 구간마다 시작/끝 시각(초, 파일 처음 기준 + offset)을 붙인다.
    static func transcribe(url: URL, speaker: String, offset: Double = 0) async throws -> [Segment] {
        let locale = Locale(identifier: "ko-KR")
        let tr = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                   attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) {
            log("ko_KR 모델 내려받는 중...")
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [tr])
        let terms = loadTerms()
        if !terms.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings = [.general: terms]
            try await analyzer.setContext(ctx)
        }
        let collector = Task { () -> [Segment] in
            var out: [Segment] = []
            for try await r in tr.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let s = r.range.start.seconds, e = r.range.end.seconds
                out.append(Segment(start: s + offset, end: (e.isFinite ? e : s) + offset, speaker: speaker, text: text))
            }
            return out
        }
        let file = try AVAudioFile(forReading: url)
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }
}

enum Merge {
    static func stamp(_ t: Double, hours: Bool) -> String {
        let s = Int(max(0, t))
        if hours { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 두 트랙을 시작 시각순으로 섞고, 같은 사람이 이어서 말한 구간(공백 2초 이내)은 한 줄로 합친다.
    static func render(_ segs: [Segment]) -> String {
        let sorted = segs.sorted { $0.start < $1.start }
        var merged: [Segment] = []
        for s in sorted {
            if var last = merged.last, last.speaker == s.speaker, s.start - last.end < 2.0 {
                last.text += " " + s.text
                last.end = max(last.end, s.end)
                merged[merged.count - 1] = last
            } else { merged.append(s) }
        }
        let hours = (merged.last?.start ?? 0) >= 3600
        return merged.map { "[\(stamp($0.start, hours: hours))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}

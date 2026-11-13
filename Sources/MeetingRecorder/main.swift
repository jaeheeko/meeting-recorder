import Foundation
import AppKit

let args = Array(CommandLine.arguments.dropFirst())

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func runCLI() async -> Int32 {
    if let c = opt("--config") { Config.fileOverride = URL(fileURLWithPath: c) }
    do {
        if let me = opt("--transcribe") {
            let other = opt("--other")
            let otherOff = Double(opt("--other-offset") ?? "0") ?? 0
            let raw = try await Pipeline.transcribeTracks(
                me: URL(fileURLWithPath: me), other: other.map { URL(fileURLWithPath: $0) },
                meOffset: 0, otherOffset: otherOff)
            if let out = opt("--out") {
                try ("# 회의 전사 원문\n녹음 시작: \(Pipeline.header(Date()))\n\n" + raw + "\n")
                    .write(toFile: out, atomically: true, encoding: .utf8)
                log("saved: \(out)")
            } else { print(raw) }
            return 0
        }
        if args.contains("--selftest") {
            func si(me: String?, other: String?, mePeak: Float?, otherPeak: Float?, w: [String] = []) -> SessionInfo {
                SessionInfo(startedAt: Date(), meFile: me, otherFile: other, meOffset: 0, otherOffset: 0, warnings: w, mePeak: mePeak, otherPeak: otherPeak, otherSilent: other == nil || (otherPeak ?? 1) < 0.003)
            }
            let cases: [(String, [String])] = [
                ("대면(상대 무음)", Pipeline.retentionReasons(si(me: "me", other: "o", mePeak: 2.3, otherPeak: 0))),
                ("마이크만(상대 트랙 없음)", Pipeline.retentionReasons(si(me: "me", other: nil, mePeak: 0.5, otherPeak: 0))),
                ("마이크 무음", Pipeline.retentionReasons(si(me: "me", other: "o", mePeak: 0.0, otherPeak: 0.4))),
                ("마이크 없음", Pipeline.retentionReasons(si(me: nil, other: "o", mePeak: 0, otherPeak: 0.4))),
                ("오류 경고", Pipeline.retentionReasons(si(me: "me", other: "o", mePeak: 0.5, otherPeak: 0.4, w: ["x"]))),
            ]
            for (n, r) in cases { print("\(n): \(r.isEmpty ? "삭제" : "보존 " + r.joined(separator: ","))") }
            // 저장 경로 정책: 패턴, 존재 확인, 확신 여부, 이탈 거부
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mr-selftest-\(getpid())")
            try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("Projects/alpha"), withIntermediateDirectories: true)
            let pol = PathPolicy(patterns: ["Unsorted/*.md", "Projects/*/notes/*.md"], fallback: "Unsorted", requireExistingParent: true, root: tmp)
            let pcases: [(String, String, Bool)] = [
                ("Projects/alpha/notes/a.md", "존재하는 프로젝트, 확신", true),
                ("Projects/alpha/notes/a.md", "존재하는 프로젝트, 불확실", false),
                ("Projects/nope/notes/a.md", "없는 프로젝트", true),
                ("Unsorted/a.md", "fallback 폴더 직접", false),
                ("Projects/alpha/../../x.md", "상위 이탈", true),
                ("/etc/a.md", "절대 경로", true),
                ("Projects/alpha/./notes/a.md", "점 성분", true),
                ("Other/a.md", "패턴 밖", true),
                (".obsidian/a.md", "숨김 폴더", true),
                ("Projects//alpha/notes/a.md", "빈 성분", true),
            ]
            for (p, n, c) in pcases { let r = pol.resolve(path: p, confident: c, defaultFileName: "d.md"); print("경로[\(n)] \(p) → \(r.path)\(r.note.map { " (\($0))" } ?? "")") }
            try? FileManager.default.removeItem(at: tmp)
            let inp = ["[00:00] 나: 예상 일정이 빠듯해요", "[02:00] 나: 네 맞아요"]
            print("validate 정상:", Corrector.validate(input: inp, output: ["[00:00] 나: 예산 일정이 빠듯해요", "[02:00] 나: 네 맞아요"]) ?? "통과")
            print("validate 화자 분리(같은 타임스탬프 두 줄):", Corrector.validate(input: inp, output: ["[00:00] 나: 예산 일정이 빠듯해요", "[00:00] Alex: 네", "[02:00] 나: 네 맞아요"]) ?? "통과")
            print("validate 줄 누락:", Corrector.validate(input: inp, output: ["[00:00] 나: 예산 일정이 빠듯해요"]) ?? "통과")
            print("validate 지나친 축약:", Corrector.validate(input: inp, output: ["[00:00] 나: 리", "[02:00] 나: 네"]) ?? "통과")
            for t in [".", "[00:00] 나: .", "[00:00] 나: 네 알겠습니다 감사합니다"] { print("meaningful(\(t)) = \(Pipeline.meaningfulCount(t))") }
            return 0
        }
        if let t = opt("--organize") {
            var cal: [CalEvent]? = nil
            if let cj = opt("--calendar-json") { cal = try JSONDecoder().decode([CalEvent].self, from: Data(contentsOf: URL(fileURLWithPath: cj))) }
            let t0 = Date()
            let plan = try Organizer.plan(transcript: URL(fileURLWithPath: t), calendar: cal, correct: !args.contains("--no-correct"))
            if let r = plan.report {
                log("교정: 덩어리 \(r.chunks)개 중 \(r.ok)개 성공, 교정 \(Int(r.seconds))초, 전체 \(Int(Date().timeIntervalSince(t0)))초")
                for f in r.failed { log("  교정 실패 \(f)") }
            }
            if args.contains("--dry-run") {
                print("PATH: \(plan.relPath)\nCONFIDENCE: \(plan.confidence)\nREASON: \(plan.reason)\n--- BODY ---\n\(plan.body)\n\n--- 이 아래에 앱이 붙이는 전사(AI 교정본) ---\n\(plan.fullDocument.components(separatedBy: "## 전사 (AI 교정본)").last ?? "")")
            } else {
                let url = try Organizer.write(plan)
                print("saved: \(url.path)")
            }
            return 0
        }
        if let d = opt("--process-session") { // 남은 세션 복구용
            let r = try await Pipeline.process(sessionDir: URL(fileURLWithPath: d))
            print(r.message); return 0
        }
        log("""
        사용법:
          MeetingRecorder                                   메뉴바 앱 실행
          MeetingRecorder --transcribe me.wav [--other other.wav] [--other-offset 초] [--out 파일]
          MeetingRecorder --organize <transcript.md> [--dry-run] [--calendar-json 파일] [--no-correct] [--config 파일]\n                                                    (--dry-run 없으면 저장 폴더에 쓴다)
          MeetingRecorder --process-session <세션 폴더>        전사 실패로 남은 오디오 복구
        """)
        return 2
    } catch {
        log("오류: \(error)"); return 1
    }
}

let cliFlags = ["--transcribe", "--organize", "--process-session", "--selftest", "--help", "-h"]
if args.contains(where: { cliFlags.contains($0) }) {
    Task { exit(await runCLI()) }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

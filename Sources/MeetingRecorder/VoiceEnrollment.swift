import Foundation
import AVFoundation

/// 내 목소리 등록: 마이크로 20초 녹음해 화자 임베딩을 저장한다. 창을 띄우지 않고 알림으로 안내한다.
enum VoiceEnrollment {
    static let seconds = 20.0
    private(set) static var running = false
    private static var engine: AVAudioEngine?

    static var registered: Bool { Diarization.loadProfile() != nil }

    static func start() {
        guard !running else { return }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { Pipeline.notify("내 목소리 등록", "마이크 권한이 필요함. 시스템 설정 > 개인정보 보호 > 마이크"); return }
                record()
            }
        }
    }

    private static func record() {
        running = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-enroll-\(getpid()).caf")
        try? FileManager.default.removeItem(at: url)
        let sink = AudioSink(url: url)
        let e = AVAudioEngine()
        do {
            try sink.prepare()
            let fmt = e.inputNode.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0 else { throw NSError(domain: "MR", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 입력을 찾지 못했다"]) }
            e.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in sink.append(buf) }
            try e.start()
        } catch {
            running = false
            Pipeline.notify("내 목소리 등록 실패", "\(error.localizedDescription)"); return
        }
        engine = e
        Pipeline.notify("내 목소리 등록", "지금부터 \(Int(seconds))초 동안 평소 말투로 말해 주세요. 혼자 있는 곳에서 하세요.")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            e.inputNode.removeTap(onBus: 0); e.stop(); engine = nil
            sink.close()
            Task.detached(priority: .utility) {
                do {
                    let p = try await Diarization.enroll(from: url)
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run { running = false }
                    Pipeline.notify("내 목소리 등록 완료", "말소리 \(Int(p.seconds))초로 등록했습니다.")
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    await MainActor.run { running = false }
                    Pipeline.notify("내 목소리 등록 실패", "\(error.localizedDescription)")
                }
            }
        }
    }
}

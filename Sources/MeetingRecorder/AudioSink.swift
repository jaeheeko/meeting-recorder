import Foundation
import AVFoundation

/// 어떤 포맷의 버퍼든 받아 16kHz 모노 Int16 CAF 로 스트리밍 기록한다(1시간 ≈ 115MB).
final class AudioSink {
    let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var closed = false
    private(set) var firstBufferAt: Date?
    private(set) var framesWritten: Int64 = 0
    /// 기록된 샘플의 최대 절대값(0~1). 무음 판단에 쓴다.
    private(set) var peak: Float = 0

    init(url: URL) { self.url = url }

    /// start 때 파일을 미리 만든다. close 뒤에 늦게 온 버퍼가 파일을 다시 열어 자르는 일을 막는다.
    func prepare() throws {
        lock.lock(); defer { lock.unlock() }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let file else { return }
        do {
            if converter == nil || converter!.inputFormat != buf.format {
                converter = AVAudioConverter(from: buf.format, to: outFormat)
                if firstBufferAt == nil { firstBufferAt = Date() }
            }
            guard let converter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if let err { log("convert error: \(err)"); return }
            if out.frameLength > 0 {
                if let ch = out.floatChannelData?[0] {
                    for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[i])) }
                }
                try file.write(from: out); framesWritten += Int64(out.frameLength)
            }
        } catch { log("sink error: \(error)") }
    }

    func close() { lock.lock(); closed = true; file = nil; converter = nil; lock.unlock() }
}

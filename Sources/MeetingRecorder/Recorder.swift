import Foundation
import AVFoundation
import CoreAudio

struct SessionInfo: Codable {
    var startedAt: Date
    var meFile: String?
    var otherFile: String?
    var meOffset: Double
    var otherOffset: Double
    var warnings: [String]
    var mePeak: Float?
    var otherPeak: Float?
    /// 상대 트랙이 없거나 무음(대면 회의로 본다).
    var otherSilent: Bool?
    var endedAt: Date?
    var calendar: [CalEvent]?
    /// nil = 처리 대기(앱 재시작 때 자동으로 이어서 처리). "failed" = 처리 실패로 오디오 보존, "kept" = 처리는 끝났고 오디오만 보존. 둘 다 자동 재처리하지 않는다.
    var state: String?
}

/// 마이크(AVAudioEngine)와 시스템 오디오(Core Audio process tap)를 별도 트랙으로 기록한다.
final class Recorder {
    let dir: URL
    private let engine = AVAudioEngine()
    private var meSink: AudioSink
    private var otherSink: AudioSink
    private let tap = SystemTap()
    private var startedAt = Date()
    private(set) var warnings: [String] = []

    init(dir: URL) {
        self.dir = dir
        meSink = AudioSink(url: dir.appendingPathComponent("me.caf"))
        otherSink = AudioSink(url: dir.appendingPathComponent("other.caf"))
    }

    private let tapQueue = DispatchQueue(label: "MeetingRecorder.tapStart")
    private let warnLock = NSLock()
    private func warn(_ w: String) { warnLock.lock(); warnings.append(w); warnLock.unlock(); log(w); Pipeline.notify("MeetingRecorder", w) }

    /// 마이크를 먼저 시작한다(실패하면 throw). 시스템 오디오 탭은 메인 스레드 밖에서 시작하고, 실패하면 경고만 남긴다.
    func start() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        startedAt = Date()
        try meSink.prepare()
        try otherSink.prepare()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "MR", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 입력을 찾지 못했다"]) }
        let sink = meSink
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in sink.append(buf) }
        try engine.start()
        let other = otherSink
        tapQueue.async { [weak self] in
            guard let self else { return }
            do { try self.tap.start(sink: other) }
            catch { self.warn("시스템 오디오 녹음 시작 실패: \(error)") }
        }
    }

    func stop() -> SessionInfo {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapQueue.sync { tap.stop() }
        meSink.close(); otherSink.close()
        let fm = FileManager.default
        let meOK = meSink.framesWritten > 0 && fm.fileExists(atPath: meSink.url.path)
        let otherOK = otherSink.framesWritten > 0 && fm.fileExists(atPath: otherSink.url.path)
        warnLock.lock(); let w = warnings; warnLock.unlock()
        let info = SessionInfo(
            startedAt: startedAt,
            meFile: meOK ? meSink.url.lastPathComponent : nil,
            otherFile: otherOK ? otherSink.url.lastPathComponent : nil,
            meOffset: meSink.firstBufferAt.map { $0.timeIntervalSince(startedAt) } ?? 0,
            otherOffset: otherSink.firstBufferAt.map { $0.timeIntervalSince(startedAt) } ?? 0,
            warnings: w, mePeak: meSink.peak, otherPeak: otherSink.peak,
            otherSilent: !otherOK || otherSink.peak < 0.003,
            endedAt: Date(), calendar: Config.load().calendarEnabled ? CalendarLookup.events(start: startedAt, end: Date()) : [])
        if let d = try? JSONEncoder().encode(info) { try? d.write(to: dir.appendingPathComponent("session.json")) }
        return info
    }
}

/// 앱 자신을 뺀 전역 출력 탭(모노). Meet·Zoom·Slack 등 모든 앱의 출력 소리를 잡는다.
final class SystemTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "MeetingRecorder.tap", qos: .userInitiated)

    struct E: Error, CustomStringConvertible { let description: String }

    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw E(description: "\(what) 실패 (OSStatus \(st))") }
    }

    private func getProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) throws -> T {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var v = initial
        try check(AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v), "속성 읽기 \(sel)")
        return v
    }

    func start(sink: AudioSink) throws {
        // 앱 자신의 process object 를 빼고 전역 탭을 만든다.
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var selfObj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &selfObj), "PID 변환")
        let excluded = selfObj == kAudioObjectUnknown ? [] : [selfObj]

        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()
        desc.name = "MeetingRecorder tap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "프로세스 탭 만들기")

        var asbd: AudioStreamBasicDescription = try getProp(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw E(description: "탭 포맷을 해석하지 못했다") }

        let outDev: AudioObjectID = try getProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
        let outUID: CFString = try getProp(outDev, kAudioDevicePropertyDeviceUID, "" as CFString)

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingRecorderTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID as String]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID), "aggregate device 만들기")
        // aggregate 의 실제 샘플레이트가 탭 포맷과 다를 수 있어 실제 값을 쓴다.
        var actualRate: Float64 = try getProp(aggID, kAudioDevicePropertyNominalSampleRate, Float64(0))
        if actualRate <= 0 { actualRate = format.sampleRate }
        var asbd2 = asbd; asbd2.mSampleRate = actualRate
        let useFormat = AVAudioFormat(streamDescription: &asbd2) ?? format
        let wantCh = Int(asbd.mChannelsPerFrame)
        log("tap format: \(asbd.mSampleRate)Hz ch=\(wantCh) / aggregate rate=\(actualRate)Hz")
        var logged = false
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inInput, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            if !logged {
                logged = true
                let desc = abl.map { "ch\($0.mNumberChannels)/\($0.mDataByteSize)B" }.joined(separator: ",")
                log("tap first callback: mNumberBuffers=\(abl.count) [\(desc)]")
            }
            if abl.count <= 1 {
                guard let buf = AVAudioPCMBuffer(pcmFormat: useFormat, bufferListNoCopy: inInput, deallocator: nil) else { return }
                sink.append(buf)
            } else {
                // 버퍼가 여러 개면(입력도 있는 출력 장치) 채널 수가 맞는 마지막 버퍼를 탭 스트림으로 본다. 탭은 sub-device 뒤에 붙는다.
                guard let pick = abl.last(where: { Int($0.mNumberChannels) == wantCh }) ?? abl.last,
                      let data = pick.mData, useFormat.channelCount == 1 else { return }
                let frames = AVAudioFrameCount(Int(pick.mDataByteSize) / MemoryLayout<Float>.size / max(1, Int(pick.mNumberChannels)))
                guard let buf = AVAudioPCMBuffer(pcmFormat: useFormat, frameCapacity: frames), let dst = buf.floatChannelData?[0] else { return }
                buf.frameLength = frames
                if pick.mNumberChannels == 1 { memcpy(dst, data, Int(frames) * MemoryLayout<Float>.size) }
                else { let src = data.assumingMemoryBound(to: Float.self); let n = Int(pick.mNumberChannels); for i in 0..<Int(frames) { dst[i] = src[i * n] } }
                sink.append(buf)
            }
        }, "IOProc 만들기")
        try check(AudioDeviceStart(aggID, procID), "탭 시작")
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

import Foundation

/// 녹음이 끝난 세션을 한 번에 하나씩 순서대로 처리하는 직렬 대기열. 처리는 낮은 QoS 로 돌려 새 녹음을 방해하지 않는다.
final class ProcessingQueue {
    struct Job {
        let id: String
        let dir: URL
        let startedAt: Date
        var stage: String
        var running: Bool
    }

    static let shared = ProcessingQueue()
    private let lock = NSLock()
    private var jobs: [Job] = []
    private var busy = false
    /// 둘 다 메인 스레드에서 호출된다.
    var onChange: (() -> Void)?
    var onFinish: ((Job, Swift.Result<Pipeline.Result, Error>) -> Void)?

    func snapshot() -> [Job] { lock.lock(); defer { lock.unlock() }; return jobs }
    var count: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }

    /// 이미 대기열에 있는 세션이면 무시한다. 대기열에 넣었으면 true.
    @discardableResult
    func enqueue(dir: URL) -> Bool {
        let id = dir.lastPathComponent
        var started = Date()
        if let d = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
           let info = try? JSONDecoder().decode(SessionInfo.self, from: d) { started = info.startedAt }
        lock.lock()
        if jobs.contains(where: { $0.id == id }) { lock.unlock(); return false }
        jobs.append(Job(id: id, dir: dir, startedAt: started, stage: "대기", running: false))
        lock.unlock()
        changed()
        kick()
        return true
    }

    private func changed() { DispatchQueue.main.async { self.onChange?() } }

    private func setStage(_ id: String, _ stage: String) {
        lock.lock()
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].stage = stage }
        lock.unlock()
        changed()
    }

    private func complete(_ id: String) {
        lock.lock(); jobs.removeAll { $0.id == id }; busy = false; lock.unlock()
    }

    private func kick() {
        lock.lock()
        guard !busy, !jobs.isEmpty else { lock.unlock(); return }
        busy = true
        jobs[0].running = true; jobs[0].stage = "전사"
        let job = jobs[0]
        lock.unlock()
        changed()
        Task.detached(priority: .utility) { [self] in
            let result: Swift.Result<Pipeline.Result, Error>
            do { result = .success(try await Pipeline.process(sessionDir: job.dir, progress: { self.setStage(job.id, $0) })) }
            catch { result = .failure(error) }
            complete(job.id)
            DispatchQueue.main.async { self.onFinish?(job, result); self.onChange?() }
            kick()
        }
    }

    /// 앱을 다시 켰을 때: 처리를 끝내지 못한 세션(state 없음)을 대기열에 다시 넣는다.
    /// 실패·보존 세션과 session.json 이 없는 폴더(녹음 중 크래시)는 건드리지 않고 개수만 돌려준다.
    static func scanLeftovers() -> (resume: [URL], preserved: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Paths.sessions.path) else { return ([], 0) }
        var resume: [URL] = [], preserved = 0
        for n in names.sorted() {
            let dir = Paths.sessions.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let d = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
               let info = try? JSONDecoder().decode(SessionInfo.self, from: d), info.state == nil,
               info.meFile != nil || info.otherFile != nil { resume.append(dir) }
            else { preserved += 1 }
        }
        return (resume, preserved)
    }
}

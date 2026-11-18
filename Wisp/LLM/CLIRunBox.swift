import Foundation

/// 一次 CLI 请求里子进程的跨线程句柄，Codex、AGY、Claude Code 三家共用。
///
/// 读循环跑在 detached task 里轮询管道，Task.isCancelled 它看不见。所以取消和
/// 超时都不去「通知」那个循环，而是直接杀进程：管道一 EOF，循环自然退出。
final class CLIRunBox: @unchecked Sendable {
    enum Stop { case cancelled, timedOut }

    private let lock = NSLock()
    private var process: Process?
    private var stopReason: Stop?
    private var settled = false

    /// 启动与取消共用同一把锁（#37）：以前登记与 run() 是两步，取消落在中间时
    /// stop() 看到进程还没跑起来就直接返回，随后 run() 却把进程拉起来了——一个
    /// 谁也杀不掉的孤儿进程。现在锁内登记并启动，已被收尾就拒绝。
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !settled else { throw ProviderError.cancelled }
        self.process = process
        try process.run()
    }

    /// - Parameter onlyIfRunning: 看门狗专用。进程已经自己退出了就什么都不做，
    ///   否则答案明明已经拿到，却还要挨一句「超时」。
    func stop(_ reason: Stop, onlyIfRunning: Bool = false) {
        lock.lock()
        // finish() 之后就不再受理：这一轮已经有结论了。
        guard !settled else { lock.unlock(); return }
        if onlyIfRunning, process?.isRunning != true { lock.unlock(); return }
        stopReason = reason
        let target = process
        settled = true
        process = nil
        lock.unlock()

        guard let target, target.isRunning else { return }
        target.terminate()
        // SIGTERM 不一定收得住，补一刀兜底。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if target.isRunning { kill(target.processIdentifier, SIGKILL) }
        }
    }

    /// 进程自己正常收尾，之后 stop() 就不该再动手。
    func finish() {
        lock.lock(); settled = true; process = nil; lock.unlock()
    }

    var reason: Stop? {
        lock.lock(); defer { lock.unlock() }
        return stopReason
    }
}

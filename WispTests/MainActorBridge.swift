import Foundation

/// Runs a @MainActor test body from a nonisolated test method.
///
/// swift-corelibs-xctest (the Linux harness in tools/linux-harness) traps when
/// its discovery meets a @MainActor test class or method, so tests whose
/// subjects are main-actor isolated (ConversationStore and friends) keep their
/// entry points nonisolated and hop in here. XCTest runs test methods on the
/// main thread on both platforms, so the body normally runs in place under an
/// isolation assertion; a semaphore hop would deadlock against the executor it
/// waits for. The hop is only the fallback for an off-main caller.
func onMainActor(_ body: @MainActor @escaping () throws -> Void) throws {
    if Thread.isMainThread {
        try MainActor.assumeIsolated { try body() }
        return
    }
    final class Box: @unchecked Sendable { var error: Error? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        do { try body() } catch { box.error = error }
        done.signal()
    }
    done.wait()
    if let error = box.error { throw error }
}

import XCTest
@testable import Wisp

/// Audit round 4, #36 (the round's most severe finding): every CLI read
/// path blocked on pipe EOF. A child process that forks a grandchild
/// holding the pipes defeats EOF entirely — the main process has
/// exited, so the watchdog's stop(onlyIfRunning:) no-ops, cancel can't
/// interrupt the blocked read, and the task/pipes/temp dir leak for the
/// life of the app. The loops now wait in poll() slices and treat
/// "process gone + pipe drained" as end of stream; CLICommand returns
/// whatever arrived instead of awaiting an EOF that will never come.
final class Round4PipeDeadlineTests: XCTestCase {

    // MARK: - PipePoll

    func testWaitReadableTimesOutWhileWriterHoldsSilently() {
        let pipe = Pipe()
        let started = Date()
        let readable = PipePoll.waitReadable(pipe.fileHandleForReading, slice: 0.3)
        XCTAssertFalse(readable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "the slice must actually bound the wait")
        pipe.fileHandleForWriting.closeFile()
    }

    func testWaitReadableSeesDataThenHangup() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("abc".utf8))
        XCTAssertTrue(PipePoll.waitReadable(pipe.fileHandleForReading, slice: 1))
        XCTAssertEqual(pipe.fileHandleForReading.availableData, Data("abc".utf8))
        pipe.fileHandleForWriting.closeFile()
        // Hangup must also wake the wait, so availableData can deliver EOF.
        XCTAssertTrue(PipePoll.waitReadable(pipe.fileHandleForReading, slice: 1))
        XCTAssertTrue(pipe.fileHandleForReading.availableData.isEmpty)
    }

    /// The CLI writes its final event and exits between a slice timing out
    /// and the isRunning check, while a descendant still holds the pipe so no
    /// hangup arrives. The tail must still be read, not dropped as "drained".
    func testAwaitDataReadsATailWrittenJustBeforeExit() throws {
        let pipe = Pipe()
        defer { pipe.fileHandleForWriting.closeFile() }
        let tail = Data("{\"type\":\"result\"}\n".utf8)
        let readable = PipePoll.awaitData(pipe.fileHandleForReading, slice: 0.05) {
            try? pipe.fileHandleForWriting.write(contentsOf: tail)
            return false
        }
        XCTAssertTrue(readable)
        XCTAssertEqual(pipe.fileHandleForReading.availableData, tail)
    }

    func testAwaitDataEndsOnceTheProcessIsGoneAndThePipeIsSilent() {
        let pipe = Pipe()
        defer { pipe.fileHandleForWriting.closeFile() }
        var checks = 0
        let readable = PipePoll.awaitData(pipe.fileHandleForReading, slice: 0.05) {
            checks += 1
            return checks < 3
        }
        XCTAssertFalse(readable, "a dead process with a silent, still-held pipe is end of stream")
        XCTAssertEqual(checks, 3, "it keeps waiting while the process runs")
    }

    // MARK: - CLICommand against a pipe-holding grandchild

    func testRunReturnsWhatArrivedDespitePipeHoldingGrandchild() async {
        // The shell prints, forks a 30 s sleeper that inherits both
        // pipes, and exits immediately. EOF never comes; run() must
        // still return once the (dead) process's output is drained.
        let started = Date()
        let result = await CLICommand.run(
            "/bin/sh",
            ["-c", "echo hello-from-child; (sleep 30 >/dev/null 2>&1 &) ; exit 0"],
            timeout: 10)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.stdout.contains("hello-from-child") ?? false,
                      "got: \(result?.stdout ?? "nil")")
        // Bounded return is the core #36 claim: before the fix this call
        // waited for the grandchild's whole 30 s (and for a daemonised
        // descendant, forever).
        XCTAssertLessThan(Date().timeIntervalSince(started), 25)
        #if os(macOS)
        // Darwin's Process tracks the child exactly; swift-corelibs'
        // isRunning latches on Linux, so there the (already dead) child
        // is misreported as running and the call takes the timeout path
        // with status -1. The strict semantics are asserted where the
        // platform provides them.
        XCTAssertEqual(result?.timedOut, false)
        XCTAssertEqual(result?.status, 0)
        #endif
    }

    func testRunStillTimesOutOnLiveHungProcess() async {
        let started = Date()
        let result = await CLICommand.run("/bin/sh", ["-c", "sleep 30"], timeout: 1)
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

import XCTest
@testable import WispCore

/// Audit round 6, part A.3: executable Python fakes standing in for the
/// real `claude` / `codex` / `agy` binaries, emitting each tool's real
/// wire format, driven through the REAL provider code (path resolution,
/// process spawn, NDJSON / JSON-RPC parsing, exit-status mapping).
/// Scripts are written to a temp dir with the exec bit set; the
/// providers find them through the configured cliPath, exactly like a
/// user-installed CLI.
///
/// Covered per provider where the format allows: success, crash after
/// partial output, stderr floods, a grandchild holding the pipes (the
/// #36 repro as a provider-level regression), and a missing binary.
/// Platform caveat asserted in-test where it bites: swift-corelibs'
/// Process.isRunning can latch, so the grandchild bounds are generous
/// and the strict semantics remain named macOS-CI checks (see doc).
final class Round6CLIProviderTests: XCTestCase {

    // MARK: - Scaffold

    private final class ChunkBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var chunks: [String] = []
        private(set) var error: Error?
        private(set) var done = false
        func add(_ chunk: String) { lock.lock(); chunks.append(chunk); lock.unlock() }
        func finish(_ error: Error?) { lock.lock(); self.error = error; done = true; lock.unlock() }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>,
                         timeout: TimeInterval) async -> (chunks: [String], error: Error?, timedOut: Bool) {
        let box = ChunkBox()
        let work = Task {
            do {
                for try await chunk in stream { box.add(chunk) }
                box.finish(nil)
            } catch {
                box.finish(error)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !box.done && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard box.done else {
            work.cancel()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return (box.chunks, box.error, true)
        }
        return (box.chunks, box.error, false)
    }

    private func writeFake(_ name: String, _ source: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-round6-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func messages() -> [[String: Any]] { [["role": "user", "content": "ping"]] }

    // MARK: - Claude Code (stream-json NDJSON)

    private let claudeOK = """
    #!/usr/bin/env python3
    import sys
    print('{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello "}}}', flush=True)
    print('{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"from fake claude"}}}', flush=True)
    print('{"type":"result","subtype":"success","is_error":false,"result":"Hello from fake claude"}', flush=True)
    """

    func testClaudeFakeSuccessAssemblesAnswer() async throws {
        let path = try writeFake("fake-claude", claudeOK)
        let provider = ClaudeCodeCLIProvider()
        let config = ProviderConfig(cliPath: path)
        let (chunks, error, timedOut) = await collect(provider.stream(messages: messages(), config: config), timeout: 20)
        XCTAssertFalse(timedOut)
        XCTAssertNil(error)
        XCTAssertEqual(chunks.joined(), "Hello from fake claude")
    }

    func testClaudeFakeCrashAfterPartialIsFailureNotPartialSuccess() async throws {
        let path = try writeFake("fake-claude", """
        #!/usr/bin/env python3
        import sys
        print('{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"half an answer"}}}', flush=True)
        print("boom: the fake exploded", file=sys.stderr, flush=True)
        sys.exit(3)
        """)
        let provider = ClaudeCodeCLIProvider()
        let (chunks, error, timedOut) = await collect(provider.stream(messages: messages(), config: ProviderConfig(cliPath: path)), timeout: 20)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(chunks, ["half an answer"], "the partial delta was streamed before the crash")
        guard case ProviderError.claudeCodeFailed(let detail, let status)? = error as? ProviderError else {
            return XCTFail("expected .claudeCodeFailed, got \(String(describing: error))")
        }
        XCTAssertEqual(status, 3)
        XCTAssertTrue(detail.contains("boom"), detail)
    }

    func testClaudeFakeStderrFloodDoesNotWedgeStdout() async throws {
        let path = try writeFake("fake-claude", """
        #!/usr/bin/env python3
        import sys
        block = "e" * 65536
        for _ in range(24):  # 1.5 MiB of stderr — far beyond the pipe buffer and the DrainBuffer tail
            sys.stderr.write(block)
            sys.stderr.flush()
        print('{"type":"result","subtype":"success","is_error":false,"result":"survived the flood"}', flush=True)
        """)
        let provider = ClaudeCodeCLIProvider()
        let (chunks, error, timedOut) = await collect(provider.stream(messages: messages(), config: ProviderConfig(cliPath: path)), timeout: 30)
        XCTAssertFalse(timedOut, "stderr must be drained concurrently or the child blocks on a full pipe")
        XCTAssertNil(error)
        XCTAssertEqual(chunks.joined(), "survived the flood")
    }

    func testClaudeFakeGrandchildHoldingPipesStillCompletes() async throws {
        // The #36 repro at provider level: the fake answers, forks a
        // 12 s grandchild that inherits BOTH pipes, and exits 0. True
        // EOF never arrives inside the window; the provider must treat
        // "process gone + drained" as the end.
        let path = try writeFake("fake-claude", """
        #!/usr/bin/env python3
        import subprocess, sys
        subprocess.Popen(["sleep", "12"], stdout=sys.stdout, stderr=sys.stderr)
        print('{"type":"result","subtype":"success","is_error":false,"result":"answered before the fork"}', flush=True)
        sys.exit(0)
        """)
        let provider = ClaudeCodeCLIProvider()
        let started = Date()
        let (chunks, error, timedOut) = await collect(provider.stream(messages: messages(), config: ProviderConfig(cliPath: path)), timeout: 25)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(timedOut, "the stream must not wait for the grandchild's EOF")
        XCTAssertNil(error)
        XCTAssertEqual(chunks.joined(), "answered before the fork")
        XCTAssertLessThan(elapsed, 11, "completion must beat the grandchild's 12 s hold; took \(elapsed)s")
    }

    func testClaudeMissingBinaryIsNotFound() async {
        let provider = ClaudeCodeCLIProvider()
        let config = ProviderConfig(cliPath: "/nonexistent/definitely-not-claude")
        let (_, error, timedOut) = await collect(provider.stream(messages: messages(), config: config), timeout: 10)
        XCTAssertFalse(timedOut)
        guard case ProviderError.claudeCodeNotFound? = error as? ProviderError else {
            return XCTFail("expected .claudeCodeNotFound, got \(String(describing: error))")
        }
    }

    // MARK: - Codex (app-server JSON-RPC over stdio)

    private let codexServerPrelude = """
    #!/usr/bin/env python3
    import json, sys

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    def read():
        line = sys.stdin.readline()
        return json.loads(line) if line.strip() else None
    """

    func testCodexFakeAppServerCompletesTurn() async throws {
        let path = try writeFake("fake-codex", codexServerPrelude + """

        while True:
            request = read()
            if request is None:
                break
            method = request.get("method")
            if method == "initialize":
                send({"id": 0, "result": {}})
            elif method == "model/list":
                send({"id": 3, "result": {"data": [
                    {"id": "fake-1", "model": "fake-model", "isDefault": True,
                     "supportedReasoningEfforts": [], "serviceTiers": []}]}})
            elif method == "thread/start":
                send({"id": 1, "result": {"thread": {"id": "thread-1"}}})
            elif method == "turn/start":
                send({"method": "item/agentMessage/delta",
                      "params": {"threadId": "thread-1", "itemId": "item-1", "delta": "Hello "}})
                send({"method": "item/agentMessage/delta",
                      "params": {"threadId": "thread-1", "itemId": "item-1", "delta": "from fake codex"}})
                send({"method": "item/completed",
                      "params": {"threadId": "thread-1",
                                 "item": {"type": "agentMessage", "id": "item-1",
                                          "text": "Hello from fake codex"}}})
                send({"method": "turn/completed",
                      "params": {"threadId": "thread-1", "turn": {"status": "completed"}}})
                break
        """)
        let provider = CodexCLIProvider()
        let config = ProviderConfig(kind: .codexCLI, cliPath: path)
        let (chunks, error, timedOut) = await collect(provider.stream(messages: messages(), config: config), timeout: 25)
        XCTAssertFalse(timedOut)
        XCTAssertNil(error)
        XCTAssertEqual(chunks.joined(), "Hello from fake codex")
    }

    func testCodexFakeCrashMidTurnIsFailure() async throws {
        let path = try writeFake("fake-codex", codexServerPrelude + """

        while True:
            request = read()
            if request is None:
                break
            method = request.get("method")
            if method == "initialize":
                send({"id": 0, "result": {}})
            elif method == "model/list":
                send({"id": 3, "result": {"data": [
                    {"id": "fake-1", "model": "fake-model", "isDefault": True,
                     "supportedReasoningEfforts": [], "serviceTiers": []}]}})
            elif method == "thread/start":
                send({"id": 1, "result": {"thread": {"id": "thread-1"}}})
            elif method == "turn/start":
                send({"method": "item/agentMessage/delta",
                      "params": {"threadId": "thread-1", "itemId": "item-1", "delta": "partial"}})
                sys.stderr.write("codex fake died here\\n")
                sys.stderr.flush()
                sys.exit(3)
        """)
        let provider = CodexCLIProvider()
        let config = ProviderConfig(kind: .codexCLI, cliPath: path)
        let (_, error, timedOut) = await collect(provider.stream(messages: messages(), config: config), timeout: 25)
        XCTAssertFalse(timedOut)
        guard case ProviderError.codexFailed? = error as? ProviderError else {
            return XCTFail("expected .codexFailed, got \(String(describing: error))")
        }
    }

    func testCodexMissingBinaryIsNotFound() async {
        let provider = CodexCLIProvider()
        let config = ProviderConfig(kind: .codexCLI, cliPath: "/nonexistent/definitely-not-codex")
        let (_, error, timedOut) = await collect(provider.stream(messages: messages(), config: config), timeout: 10)
        XCTAssertFalse(timedOut)
        guard case ProviderError.codexNotFound? = error as? ProviderError else {
            return XCTFail("expected .codexNotFound, got \(String(describing: error))")
        }
    }

    // MARK: - AGY (stream-json, step_update + result)

    func testAgyFakeSuccessAssemblesAnswer() async throws {
        let path = try writeFake("fake-agy", """
        #!/usr/bin/env python3
        import sys
        if len(sys.argv) > 1 and sys.argv[1] == "--version":
            print("1.1.27")
            sys.exit(0)
        print('{"event":"step_update","step_update":{"step_type":"agent_response","step_index":0,"text_delta":"Hello "}}', flush=True)
        print('{"event":"step_update","step_update":{"step_type":"agent_response","step_index":0,"text_delta":"from fake agy"}}', flush=True)
        print('{"event":"result","result":{"status":"SUCCESS","response":"Hello from fake agy"}}', flush=True)
        """)
        let provider = AgyCLIProvider()
        let config = ProviderConfig(cliPath: path)
        let (chunks, error, timedOut) = await collect(provider.stream(messages: messages(), config: config), timeout: 20)
        XCTAssertFalse(timedOut)
        XCTAssertNil(error)
        XCTAssertEqual(chunks.joined(), "Hello from fake agy")
    }

    func testAgyFakeFailureResultIsFailure() async throws {
        let path = try writeFake("fake-agy", """
        #!/usr/bin/env python3
        import sys
        print('{"event":"result","result":{"status":"FAILURE","error":"agy fake quota exhausted"}}', flush=True)
        """)
        let provider = AgyCLIProvider()
        let (chunks, error, timedOut) = await collect(provider.stream(messages: messages(), config: ProviderConfig(cliPath: path)), timeout: 20)
        XCTAssertFalse(timedOut)
        XCTAssertEqual(chunks, [])
        guard case ProviderError.agyFailed(let detail, _)? = error as? ProviderError else {
            return XCTFail("expected .agyFailed, got \(String(describing: error))")
        }
        XCTAssertTrue(detail.contains("quota exhausted"), detail)
    }

    func testAgyMissingBinaryIsNotFound() async {
        let provider = AgyCLIProvider()
        let config = ProviderConfig(cliPath: "/nonexistent/definitely-not-agy")
        let (_, error, timedOut) = await collect(provider.stream(messages: messages(), config: config), timeout: 15)
        XCTAssertFalse(timedOut)
        guard case ProviderError.agyNotFound? = error as? ProviderError else {
            return XCTFail("expected .agyNotFound, got \(String(describing: error))")
        }
    }
}

import XCTest
@testable import WispCore

/// Audit round 6, part A.1/A.2 (real-socket leg): a throwaway Python
/// HTTP server on 127.0.0.1 serving scripted responses, driven through
/// the app's REAL provider + Ollama probe code over a real TCP
/// connection — no URLProtocol, no shimmed transport (the provider's
/// loopback HTTP exception is the designed seam: endpoint() allows
/// http only for loopback hosts). The server script is written to a
/// temp directory by the test; nothing here touches app sources.
///
/// Modes: cloud-ok (SSE in flushed pieces), cloud-400 (JSON error),
/// models-ok / models-wrongshape (the Ollama /v1/models probe shapes —
/// the wrong shape is exactly what a native /api/tags-style payload
/// looks like, the #50 regression), models-empty (data: [] is a REAL
/// zero-model answer and must read as running, not failed).
final class Round6RealServerTests: XCTestCase {

    private static let serverSource = """
    import sys, time
    from http.server import BaseHTTPRequestHandler, HTTPServer

    mode = sys.argv[1]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body, content_type="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.endswith("/models"):
                if mode == "models-ok":
                    self.reply(200, b'{"data":[{"id":"fake-b"},{"id":"fake-a"}]}')
                elif mode == "models-empty":
                    self.reply(200, b'{"data":[]}')
                elif mode == "models-wrongshape":
                    self.reply(200, b'{"models":[{"name":"fake-a","size":1}]}')
                else:
                    self.reply(404, b'{}')
            else:
                self.reply(404, b'{}')

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            if mode == "cloud-400":
                self.reply(400, b'{"error":{"message":"real-server says no"}}')
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            pieces = [
                b'data: {"choices":[{"delta":{"content":"real "}}]}\\n\\n',
                b'data: {"choices":[{"delta":{"content":"socket "}}]}\\n\\n',
                b'data: {"choices":[{"delta":{"content":"answer"}}]}\\n\\n',
                b'data: [DONE]\\n\\n',
            ]
            for piece in pieces:
                self.wfile.write(piece)
                self.wfile.flush()
                time.sleep(0.01)

    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
    """

    private var serverProcess: Process?
    private var serverPort: Int?

    override func tearDown() {
        serverProcess?.terminate()
        serverProcess = nil
        serverPort = nil
        super.tearDown()
    }

    private func startServer(mode: String) throws -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-round6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try Self.serverSource.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, mode]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        serverProcess = process

        // The server prints its ephemeral port as its first line.
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let chunk = stdout.fileHandleForReading.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
                if let text = String(data: buffer, encoding: .utf8),
                   let line = text.split(separator: "\n").first,
                   let port = Int(line) {
                    serverPort = port
                    return port
                }
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NSError(domain: "Round6RealServer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "server did not report a port"])
    }

    private func baseURL(_ port: Int) -> String { "http://127.0.0.1:\(port)/v1" }

    // MARK: - Cloud provider over a real socket

    func testCloudSSEOverRealSocket() async throws {
        let port = try startServer(mode: "cloud-ok")
        let provider = OpenAICompatibleProvider()
        let config = ProviderConfig(baseURL: baseURL(port), apiKey: "placeholder", model: "fake")
        var chunks: [String] = []
        for try await chunk in provider.stream(messages: [["role": "user", "content": "q"]],
                                               config: config) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, ["real ", "socket ", "answer"])
    }

    func testCloud400OverRealSocketMapsMessage() async throws {
        let port = try startServer(mode: "cloud-400")
        let provider = OpenAICompatibleProvider()
        let config = ProviderConfig(baseURL: baseURL(port), apiKey: "placeholder", model: "fake")
        do {
            for try await _ in provider.stream(messages: [["role": "user", "content": "q"]],
                                               config: config) {}
            XCTFail("a 400 must throw")
        } catch let error as ProviderError {
            guard case .http(let code, let message) = error else {
                return XCTFail("expected .http, got \(error)")
            }
            XCTAssertEqual(code, 400)
            XCTAssertTrue(message.contains("real-server says no"), message)
        }
    }

    // MARK: - Ollama probe against scripted /v1/models shapes

    func testOllamaProbeRunningSortsModelIDs() async throws {
        let port = try startServer(mode: "models-ok")
        let status = await OllamaSupport.probe(baseURL: baseURL(port))
        guard case .running(let models) = status else {
            return XCTFail("expected .running, got \(status)")
        }
        XCTAssertEqual(models, ["fake-a", "fake-b"])
    }

    func testOllamaProbeEmptyDataIsRunningWithZeroModels() async throws {
        let port = try startServer(mode: "models-empty")
        let status = await OllamaSupport.probe(baseURL: baseURL(port))
        guard case .running(let models) = status else {
            return XCTFail("expected .running([]), got \(status)")
        }
        XCTAssertEqual(models, [])
    }

    func testOllamaProbeWrongShapeIsFailedNotRunning() async throws {
        // The #50 regression: an unrecognized shape must never read as
        // "running with zero models".
        let port = try startServer(mode: "models-wrongshape")
        let status = await OllamaSupport.probe(baseURL: baseURL(port))
        guard case .failed = status else {
            return XCTFail("expected .failed for a wrong-shape body, got \(status)")
        }
    }

    func testOllamaProbeConnectionRefusedIsNotRunning() async throws {
        // Reserve an ephemeral port and release it, so nothing listens:
        // bind via a one-shot python, read the port, let it exit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
        import socket
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        print(sock.getsockname()[1], flush=True)
        """]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(port, 0)
        let status = await OllamaSupport.probe(baseURL: baseURL(port))
        guard case .notRunning = status else {
            return XCTFail("expected .notRunning, got \(status)")
        }
    }
}

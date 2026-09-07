import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Wisp

final class PrivacyTransportTests: XCTestCase {
    func testRemoteTransportRequiresTLSButLocalOllamaStillWorks() {
        XCTAssertNotNil(OpenAICompatibleProvider.endpoint("https://api.example.test/v1"))
        XCTAssertNotNil(OpenAICompatibleProvider.endpoint("http://localhost:11434/v1"))
        XCTAssertNotNil(OpenAICompatibleProvider.endpoint("http://127.0.0.1:11434/v1"))
        XCTAssertNotNil(OpenAICompatibleProvider.endpoint("http://[::1]:11434/v1"))
        XCTAssertNil(OpenAICompatibleProvider.endpoint("http://api.example.test/v1"))
        XCTAssertNil(OpenAICompatibleProvider.endpoint("http://192.168.1.2:11434/v1"))
        XCTAssertNil(OpenAICompatibleProvider.endpoint("https://user:secret@api.example.test/v1"))
        XCTAssertNil(OpenAICompatibleProvider.endpoint("https://api.example.test/v1?key=secret"))
    }

    func testSyntheticValidationRequestUsesOnlyConfiguredEndpoint() async throws {
        let config = OpenAICompatibleProvider.privateSessionConfiguration()
        config.protocolClasses = [SyntheticAPIProtocol.self]
        let provider = OpenAICompatibleProvider(configuration: config)
        try await provider.validate(config: ProviderConfig(kind: .openAICompatible,
            baseURL: "https://api.example.test/v1", apiKey: "synthetic-key", model: "synthetic-model"))
    }

    func testCaptureTransportHasNoPersistentStoresOrCookies() {
        let config = OpenAICompatibleProvider.privateSessionConfiguration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRedirectCannotForwardPrivateRequestToAnotherHost() async throws {
        let original = URL(string: "https://api.example.test/v1/chat/completions")!
        let destination = URL(string: "https://other.example.test/collect")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original) // Deliberately never resumed.
        let response = HTTPURLResponse(url: original, statusCode: 307,
                                       httpVersion: nil, headerFields: ["Location": destination.absoluteString])!
        var request = URLRequest(url: destination)
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic private page".utf8)
        let forwarded: URLRequest? = await withCheckedContinuation { continuation in
            PrivateAPIRedirectPolicy().urlSession(session, task: task,
                willPerformHTTPRedirection: response, newRequest: request) {
                    continuation.resume(returning: $0)
                }
        }
        XCTAssertNil(forwarded)
    }

    func testExistingStorageDirectoryIsRestrictedWithoutLosingContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wisp-storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("conversation.json")
        let contents = Data("synthetic conversation".utf8)
        try contents.write(to: file)
        try AppSettings.ensurePrivateDirectory(directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }
}

private final class SyntheticAPIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ClaudeCodeCLIProviderTests: XCTestCase {
    func testCommandIsRestrictedToReadAndDoesNotPersistSession() {
        let arguments = ClaudeCodeCLIProvider.commandArguments(prompt: "question", model: "sonnet")

        XCTAssertTrue(arguments.contains("--restricted"))
        XCTAssertEqual(value(after: "--tools", in: arguments), "Read")
        XCTAssertEqual(value(after: "--allowedTools", in: arguments), "Read")
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertEqual(value(after: "--model", in: arguments), "sonnet")
    }

    func testAuthExitCodeOneIsSignedOut() {
        XCTAssertEqual(
            ClaudeCodeCLIProvider.authenticationState(status: 1, stdout: ""),
            .signedOut
        )
    }

    func testAuthJSONCanReportSignedOut() {
        XCTAssertEqual(
            ClaudeCodeCLIProvider.authenticationState(
                status: 0,
                stdout: #"{"loggedIn":false}"#
            ),
            .signedOut
        )
    }

    func testOtherNonzeroAuthExitIsFailure() {
        XCTAssertEqual(
            ClaudeCodeCLIProvider.authenticationState(status: 2, stdout: ""),
            .failed
        )
    }

    func testOnlyTextDeltaIsExposedAsAnswerText() {
        let textLine = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}"#
        let thinkingLine = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"secret"}}}"#

        guard case .text(let text) = ClaudeCodeCLIProvider.event(in: textLine) else {
            return XCTFail("Expected a text event")
        }
        XCTAssertEqual(text, "hello")
        guard case .none = ClaudeCodeCLIProvider.event(in: thinkingLine) else {
            return XCTFail("Thinking content must not enter the answer")
        }
    }

    func testCompletionRequiresSuccessfulResultAndZeroExitCode() {
        let success = ClaudeCodeCLIProvider.Outcome(isError: false, text: "done")
        let failure = ClaudeCodeCLIProvider.Outcome(isError: true, text: "failed")

        XCTAssertTrue(ClaudeCodeCLIProvider.isSuccessfulCompletion(outcome: success, status: 0))
        XCTAssertFalse(ClaudeCodeCLIProvider.isSuccessfulCompletion(outcome: nil, status: 0))
        XCTAssertFalse(ClaudeCodeCLIProvider.isSuccessfulCompletion(outcome: success, status: 9))
        XCTAssertFalse(ClaudeCodeCLIProvider.isSuccessfulCompletion(outcome: failure, status: 0))
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

final class CLIPromptTests: XCTestCase {
    func testPromptEstimatorCountsWideCharactersConservatively() {
        XCTAssertEqual(CLIPrompt.estimatedTokens("测试abcde"), 3)
    }

    func testOversizedPromptIsTruncated() {
        let original = String(repeating: "甲", count: 5_000)
        let fitted = CLIPrompt.fit([original], budget: 3_000)

        XCTAssertEqual(fitted.count, 1)
        XCTAssertLessThan(fitted[0].count, original.count)
        XCTAssertLessThanOrEqual(CLIPrompt.estimatedTokens(fitted[0]), 3_100)
    }
}

final class CLITemporaryDirectoryTests: XCTestCase {
    func testTemporaryDirectoryIsPrivateAndRemoved() throws {
        let directory = try CLITemporaryDirectory.create(prefix: "Wisp-test")
        defer { CLITemporaryDirectory.remove(directory) }

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o700)

        let screenshot = directory.appendingPathComponent("screen.jpg")
        try Data("image".utf8).write(to: screenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot.path))
        XCTAssertTrue(CLITemporaryDirectory.remove(directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

final class AdvancedShortcutTests: XCTestCase {
    func testAdvancedShortcutRoundTripsFunctionAndShiftModifiers() throws {
        let shortcut = AdvancedShortcut(
            keyCode: UInt16(kVK_Space),
            kind: .key,
            modifiers: [.function, .shift]
        )

        let data = try JSONEncoder().encode(shortcut)
        let restored = try JSONDecoder().decode(AdvancedShortcut.self, from: data)

        XCTAssertEqual(restored, shortcut)
        XCTAssertTrue(restored.eventModifiers.contains(.function))
        XCTAssertTrue(restored.eventModifiers.contains(.shift))
    }

    func testShortcutModesExposeExpectedTapCounts() {
        XCTAssertNil(ShortcutTriggerMode.standard.tapCount)
        XCTAssertEqual(ShortcutTriggerMode.enhancedSingle.tapCount, 1)
        XCTAssertEqual(ShortcutTriggerMode.doubleTap.tapCount, 2)
        XCTAssertEqual(ShortcutTriggerMode.tripleTap.tapCount, 3)
    }

    func testFunctionKeyNamesUseCarbonKeyMapInsteadOfNumericOffsets() {
        let cases: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F5, "F5"),
            (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F20, "F20"),
        ]

        for (keyCode, expected) in cases {
            XCTAssertEqual(ShortcutKeyInfo.name(for: UInt16(keyCode), kind: .key), expected)
        }
    }
}

final class MarkdownBlockTests: XCTestCase {
    func testParsesStandardTableSeparator() {
        let blocks = MarkdownBlock.parse("| Name | Value |\n| --- | :---: |\n| Wisp | 1 |")

        guard case .table(let headers, let rows) = blocks.first else {
            return XCTFail("Expected a Markdown table")
        }
        XCTAssertEqual(headers, ["Name", "Value"])
        XCTAssertEqual(rows, [["Wisp", "1"]])
    }

    func testDoesNotTreatSingleDashesAsTableSeparator() {
        let blocks = MarkdownBlock.parse("A | B\n- | -")

        XCTAssertFalse(blocks.contains { block in
            if case .table = block { return true }
            return false
        })
    }
}

final class BrowserPrivacyTests: XCTestCase {
    func testPageCollectorCleanupScriptRemovesTemporaryPageState() {
        XCTAssertTrue(PageTextScript.cleanupJS.contains("window.__wispCollector = null"))
    }
}

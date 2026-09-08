import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Wisp

final class CLIStreamingTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func codexSession() throws -> CodexCLIProvider.AppServerSession {
        var state = CodexCLIProvider.AppServerSession(prompt: "question", imagePaths: ["/tmp/screen.jpg"],
                                                     directory: "/tmp/private-workspace", model: "test-model")
        let handshake = try state.receive(json(#"{"id":0,"result":{}}"#))
        XCTAssertEqual(handshake.requests[0]["method"] as? String, "initialized")
        XCTAssertEqual(handshake.requests[1]["method"] as? String, "model/list")
        let listing = try state.receive(json(#"{"id":3,"result":{"data":[{"model":"test-model","serviceTiers":[{"id":"priority","name":"Fast"}]}]}}"#))
        let params = try XCTUnwrap(listing.requests[0]["params"] as? [String: Any])
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params["model"] as? String, "test-model")
        XCTAssertEqual(params["serviceTier"] as? String, "priority")
        let start = try state.receive(json(#"{"id":1,"result":{"thread":{"id":"t"}}}"#))
        let turn = try XCTUnwrap(start.requests.first?["params"] as? [String: Any])
        let input = try XCTUnwrap(turn["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["type"] as? String, "localImage")
        XCTAssertEqual(input.last?["path"] as? String, "/tmp/screen.jpg")
        return state
    }

    func testFramingPreservesSplitUnicodeAndUnterminatedFinalLine() throws {
        let bytes = Data("{\"text\":\"你好🌤\"}\n{\"text\":\"end\"}".utf8)
        var parser = CLIJSONLines()
        var result: [[String: Any]] = []
        for byte in bytes { result += try parser.append(Data([byte])) }
        result += try parser.append(Data(), endOfFile: true)
        XCTAssertEqual(result.compactMap { $0["text"] as? String }, ["你好🌤", "end"])
        XCTAssertThrowsError(try parser.append(Data("not json\n".utf8)))
    }

    func testCodexDeltasIgnoreReasoningAndDoNotRepeatSnapshot() throws {
        var state = try codexSession()
        XCTAssertEqual(try state.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"t","itemId":"a","delta":"Hello"}}"#)).text, ["Hello"])
        XCTAssertTrue(try state.receive(json(#"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"t","delta":"private"}}"#)).text.isEmpty)
        XCTAssertTrue(try state.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"other","itemId":"a","delta":"wrong"}}"#)).text.isEmpty)
        XCTAssertEqual(try state.receive(json(#"{"method":"item/completed","params":{"threadId":"t","item":{"type":"agentMessage","id":"a","text":"Hello world"}}}"#)).text, [" world"])
        XCTAssertTrue(try state.receive(json(#"{"method":"item/completed","params":{"threadId":"t","item":{"type":"agentMessage","id":"a","text":"Hello world"}}}"#)).text.isEmpty)
        XCTAssertFalse(state.completed)
        _ = try state.receive(json(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"status":"completed"}}}"#))
        XCTAssertTrue(state.completed)
    }

    func testCodexFailuresAndApprovalRequestsAreNotSuccess() throws {
        var state = try codexSession()
        XCTAssertThrowsError(try state.receive(json(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"status":"failed","error":{"message":"offline"}}}}"#)))
        XCTAssertFalse(state.completed)
        XCTAssertThrowsError(try state.receive(json(#"{"id":2,"error":{"code":-1,"message":"bad model"}}"#)))
        XCTAssertThrowsError(try state.receive(json(#"{"id":"approval","method":"item/commandExecution/requestApproval","params":{}}"#)))
    }

    func testCodexDoesNotForceFastOnUnsupportedModel() throws {
        var state = CodexCLIProvider.AppServerSession(prompt: "q", imagePaths: [], directory: "/tmp", model: "mini")
        _ = try state.receive(json(#"{"id":0,"result":{}}"#))
        let listing = try state.receive(json(#"{"id":3,"result":{"data":[{"model":"mini","serviceTiers":[]}]}}"#))
        let params = try XCTUnwrap(listing.requests[0]["params"] as? [String: Any])
        XCTAssertEqual(params["serviceTier"] as? String, "default")
        XCTAssertEqual(params["model"] as? String, "mini")
    }

    func testCodexFastRejectionFallsBackOnceWithoutChangingModel() throws {
        var state = try codexSession()
        let retry = try state.receive(json(#"{"method":"error","params":{"threadId":"t","willRetry":false,"error":{"message":"priority service tier is not available for this account"}}}"#))
        let params = try XCTUnwrap(retry.requests.first?["params"] as? [String: Any])
        XCTAssertEqual(params["serviceTier"] as? String, "default")
        XCTAssertEqual(params["model"] as? String, "test-model")
        XCTAssertNil(state.threadID)
        XCTAssertTrue(try state.receive(json(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"status":"failed"}}}"#)).requests.isEmpty)
        XCTAssertThrowsError(try state.receive(json(#"{"id":1,"error":{"message":"priority service tier is unavailable"}}"#)))
    }

    func testCodexDoesNotRetryFastFailureAfterTextWasDelivered() throws {
        var state = try codexSession()
        _ = try state.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"t","itemId":"a","delta":"partial"}}"#))
        XCTAssertThrowsError(try state.receive(json(#"{"method":"error","params":{"threadId":"t","willRetry":false,"error":{"message":"fast mode failed"}}}"#)))
    }

    func testAgyOnlyStreamsAgentTextAndDoesNotRepeatResult() throws {
        var state = AgyCLIProvider.StreamState()
        XCTAssertNil(try state.receive(json(#"{"event":"step_update","step_update":{"step_type":"tool_call","text_delta":"private"}}"#)))
        XCTAssertEqual(try state.receive(json(#"{"event":"step_update","step_update":{"step_index":1,"step_type":"agent_response","text_delta":"Hello "}}"#)), "Hello ")
        XCTAssertEqual(try state.receive(json(#"{"event":"step_update","step_update":{"step_index":1,"step_type":"agent_response","state":"DONE","text_delta":"world"}}"#)), "world")
        XCTAssertFalse(state.completed)
        XCTAssertNil(try state.receive(json(#"{"event":"result","result":{"status":"SUCCESS","response":"Hello world"}}"#)))
        XCTAssertTrue(state.completed)
    }

    func testAgyFinalOnlyFallbackAndFailures() throws {
        var state = AgyCLIProvider.StreamState()
        XCTAssertEqual(try state.receive(json(#"{"event":"result","result":{"status":"SUCCESS","response":"fallback"}}"#)), "fallback")
        var failed = AgyCLIProvider.StreamState()
        _ = try failed.receive(json(#"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"partial"}}"#))
        XCTAssertThrowsError(try failed.receive(json(#"{"event":"result","result":{"status":"ERROR","error":"offline"}}"#)))
        XCTAssertFalse(failed.completed)
        var empty = AgyCLIProvider.StreamState()
        XCTAssertThrowsError(try empty.receive(json(#"{"event":"result","result":{"status":"SUCCESS","response":" "}}"#)))
    }

    func testProvidersYieldBeforeProcessFinishesAndCleanWorkspace() async throws {
        for codex in [true, false] {
            let directory = try CLITemporaryDirectory.create(prefix: "Wisp-stream-test")
            defer { CLITemporaryDirectory.remove(directory) }
            let binary = directory.appendingPathComponent("fixture")
            let marker = directory.appendingPathComponent("finished")
            let workspace = directory.appendingPathComponent("workspace")
            // Synthetic subprocess only; no installed model CLI, account or screenshot is accessed.
            let script = """
            #!/usr/bin/python3
            import json,sys,time,os
            def emit(value):
                print(json.dumps(value),flush=True)
            open('\(workspace.path)','w').write(os.getcwd())
            if '\(codex)' == 'true':
                assert sys.argv[1:] == ['app-server','--listen','stdio://']
                assert json.loads(input())['method'] == 'initialize'
                emit({'id':0,'result':{}})
                assert json.loads(input())['method'] == 'initialized'
                assert json.loads(input())['method'] == 'model/list'
                emit({'id':3,'result':{'data':[{'model':'fixture','serviceTiers':[{'id':'priority','name':'Fast'}]}]}})
                request=json.loads(input())
                assert request['params']['ephemeral'] and request['params']['sandbox']=='read-only'
                assert request['params']['serviceTier']=='priority'
                emit({'id':1,'result':{'thread':{'id':'t'}}})
                assert json.loads(input())['method']=='turn/start'
                emit({'method':'item/agentMessage/delta','params':{'threadId':'t','itemId':'a','delta':'first'}})
            else:
                assert sys.argv[sys.argv.index('--output-format')+1]=='stream-json'
                emit({'event':'step_update','step_update':{'step_type':'agent_response','text_delta':'first'}})
            time.sleep(1)
            open('\(marker.path)','w').write('done')
            if '\(codex)' == 'true':
                emit({'method':'item/completed','params':{'threadId':'t','item':{'type':'agentMessage','id':'a','text':'first second'}}})
                emit({'method':'turn/completed','params':{'threadId':'t','turn':{'status':'completed'}}})
                time.sleep(30)
            else:
                sys.stdout.write(json.dumps({'event':'result','result':{'status':'SUCCESS','response':'first second'}}))
                sys.stdout.flush()
            """
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let provider: any ChatProvider = codex ? CodexCLIProvider() : AgyCLIProvider()
            let config = ProviderConfig(kind: .codexCLI, model: "fixture", cliPath: binary.path)
            var chunks: [String] = []
            for try await chunk in provider.stream(messages: [["role": "user", "content": "synthetic"]], config: config) {
                if chunks.isEmpty { XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)) }
                chunks.append(chunk)
            }
            XCTAssertEqual(chunks, ["first", " second"])
            let workPath = try String(contentsOf: workspace, encoding: .utf8)
            for _ in 0..<100 where FileManager.default.fileExists(atPath: workPath) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: workPath))
        }
    }
    func testCancellationStopsBlockedCLIAndRemovesWorkspace() async throws {
        for codex in [true, false] {
            let directory = try CLITemporaryDirectory.create(prefix: "Wisp-cancel-test")
            defer { CLITemporaryDirectory.remove(directory) }
            let binary = directory.appendingPathComponent("fixture")
            let workspace = directory.appendingPathComponent("workspace")
            let script = """
            #!/usr/bin/python3
            import json,os,time,signal
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            def emit(value): print(json.dumps(value),flush=True)
            open('\(workspace.path)','w').write(os.getcwd())
            if '\(codex)' == 'true':
                input();emit({'id':0,'result':{}})
                input();input();emit({'id':3,'result':{'data':[]}})
                input();emit({'id':1,'result':{'thread':{'id':'t'}}})
                input();emit({'method':'item/agentMessage/delta','params':{'threadId':'t','itemId':'a','delta':'first'}})
            else:
                emit({'event':'step_update','step_update':{'step_type':'agent_response','text_delta':'first'}})
            time.sleep(30)
            """
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let firstChunk = expectation(description: "first chunk before cancellation")
            let provider: any ChatProvider = codex ? CodexCLIProvider() : AgyCLIProvider()
            let config = ProviderConfig(kind: .codexCLI, model: "fixture", cliPath: binary.path)
            let reader = Task {
                do {
                    for try await _ in provider.stream(messages: [], config: config) { firstChunk.fulfill() }
                } catch { /* Cancellation may finish iteration or throw. */ }
            }
            await fulfillment(of: [firstChunk], timeout: 5)
            reader.cancel()
            await reader.value
            let workPath = try String(contentsOf: workspace, encoding: .utf8)
            for _ in 0..<150 where FileManager.default.fileExists(atPath: workPath) {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: workPath), "Blocked process must be stopped before workspace cleanup")
        }
    }

    func testProviderEOFWithoutCompletionFailsEvenAfterText() async throws {
        for codex in [true, false] {
            let directory = try CLITemporaryDirectory.create(prefix: "Wisp-eof-test")
            defer { CLITemporaryDirectory.remove(directory) }
            let binary = directory.appendingPathComponent("fixture")
            let script = """
            #!/usr/bin/python3
            import json
            def emit(value): print(json.dumps(value),flush=True)
            if '\(codex)' == 'true':
                input();emit({'id':0,'result':{}})
                input();input();emit({'id':3,'result':{'data':[]}})
                input();emit({'id':1,'result':{'thread':{'id':'t'}}})
                input();emit({'method':'item/agentMessage/delta','params':{'threadId':'t','itemId':'a','delta':'partial'}})
            else:
                emit({'event':'step_update','step_update':{'step_type':'agent_response','text_delta':'partial'}})
            """
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let provider: any ChatProvider = codex ? CodexCLIProvider() : AgyCLIProvider()
            let config = ProviderConfig(kind: .codexCLI, model: "fixture", cliPath: binary.path)
            var text = ""
            do {
                for try await chunk in provider.stream(messages: [], config: config) { text += chunk }
                XCTFail("EOF without a completion event must fail")
            } catch { XCTAssertEqual(text, "partial") }
        }
    }
}

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
    func testFastDefaultsOnForSupportedOpusWithoutChangingSelectedModel() throws {
        for model in ["opus", "opus[1m]", "claude-opus-5", "claude-opus-4-8"] {
            let arguments = ClaudeCodeCLIProvider.commandArguments(prompt: "q", model: model)
            let settings = try XCTUnwrap(value(after: "--settings", in: arguments))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any])
            XCTAssertEqual(object["fastMode"] as? Bool, true)
            XCTAssertEqual(value(after: "--model", in: arguments), model)
            XCTAssertTrue(arguments.contains("--restricted"))
        }
        for model in ["sonnet", "haiku", "claude-opus-4-7", "", "custom-model"] {
            let arguments = ClaudeCodeCLIProvider.commandArguments(prompt: "q", model: model)
            XCTAssertFalse(arguments.contains("--settings"))
        }
    }

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

final class SpeedPreferenceTests: XCTestCase {
    private func body(_ model: String, at base: String) throws -> [String: Any] {
        let endpoint = try XCTUnwrap(OpenAICompatibleProvider.endpoint(base))
        return OpenAICompatibleProvider.speedPreferredBody(
            ["model": model, "stream": true, "messages": [["role": "user", "content": "synthetic"]]],
            endpoint: endpoint)
    }

    func testOpenRouterPresetsKeepOrderAndFreeModelIdentity() throws {
        let presets = CloudProvider.openRouter.presets
        XCTAssertEqual(presets.map(\.slug), ["openai/gpt-5.6-luna", "z-ai/glm-5.3-flash",
            "qwen/qwen3.7-flash", "minimax/minimax-m3:free", "thinkingmachines/inkling:free"])
        for preset in presets {
            let result = try body(preset.slug, at: "https://openrouter.ai/api/v1/")
            XCTAssertEqual(result["model"] as? String, preset.slug)
            let routing = try XCTUnwrap(result["provider"] as? [String: Any])
            XCTAssertEqual(routing["sort"] as? String, "throughput")
            XCTAssertEqual(routing["allow_fallbacks"] as? Bool, true)
            if preset.slug.hasSuffix(":free") { XCTAssertNil(result["service_tier"]) }
            else { XCTAssertEqual(result["service_tier"] as? String, "priority") }
            XCTAssertEqual(result["stream"] as? Bool, true)
            XCTAssertEqual((result["messages"] as? [[String: String]])?.first?["content"], "synthetic")
        }
    }

    func testDirectAPIsRequestPriorityWithoutChangingModel() throws {
        for (base, model) in [("https://api.openai.com/v1", "gpt-5.6-luna"),
                              ("https://generativelanguage.googleapis.com/v1beta/openai", "gemini-3.7-flash")] {
            let result = try body(model, at: base)
            XCTAssertEqual(result["service_tier"] as? String, "priority")
            XCTAssertEqual(result["model"] as? String, model)
            XCTAssertNil(result["provider"])
        }
    }

    func testOtherHostsAndPathsDoNotReceiveVendorOptions() throws {
        for base in ["https://api.example.test/v1", "http://localhost:11434/v1",
                     "https://openrouter.ai.example.test/api/v1", "https://openrouter.ai/custom",
                     "https://api.anthropic.com/v1", "https://open.bigmodel.cn/api/paas/v4"] {
            let result = try body("synthetic", at: base)
            XCTAssertNil(result["service_tier"])
            XCTAssertNil(result["provider"])
        }
    }
}

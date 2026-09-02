import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Wisp

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
}

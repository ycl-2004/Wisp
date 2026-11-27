import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Wisp

final class AuditFixes20261126Tests: XCTestCase {

    // MARK: - ModelCatalog & CLI Providers

    func testParseTopLevelTOMLModelIgnoresProfileTablesAndInlineComments() throws {
        let toml = """
        # Codex configuration
        approval_policy = "never"
        model = "gpt-5.6-luna" # inline comment
        [profiles.fast]
        model = "wrong-profile-model"
        """
        XCTAssertEqual(ModelCatalog.parseTopLevelTOMLModel(toml), "gpt-5.6-luna")
        XCTAssertEqual(ModelCatalog.parseTopLevelTOMLModel("model = 'o4-mini'\r\n[mcp]\r\nmodel = 'ignored'"), "o4-mini")
        XCTAssertNil(ModelCatalog.parseTopLevelTOMLModel("[profiles.only]\nmodel = \"not-top-level\"\n"))

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try toml.write(to: tempDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ModelCatalog.codexConfiguredModel(codexHome: tempDir.path), "gpt-5.6-luna")
    }

    func testHighThinkingSiblingPreservesXHighAndFallsBackWhenHighAbsent() {
        let neonPresets = ["gemini-4-neon-low", "gemini-4-neon-high", "gemini-4-neon-xhigh"]
            .map { ModelCatalog.Preset(slug: $0, title: $0, note: "") }
        XCTAssertEqual(ModelCatalog.highThinkingSibling(of: "gemini-4-neon-low", in: neonPresets), "gemini-4-neon-high")
        XCTAssertNil(ModelCatalog.highThinkingSibling(of: "gemini-4-neon-xhigh", in: neonPresets),
                     "explicit -xhigh must never be downgraded to -high")

        let xhighOnly = ["custom-reasoner-low", "custom-reasoner-xhigh"]
            .map { ModelCatalog.Preset(slug: $0, title: $0, note: "") }
        XCTAssertEqual(ModelCatalog.highThinkingSibling(of: "custom-reasoner-low", in: xhighOnly), "custom-reasoner-xhigh")
    }

    func testAgyStreamStateMapsPrintTimeoutToTimedOutError() {
        var state = AgyCLIProvider.StreamState()
        let payload: [String: Any] = [
            "event": "result",
            "result": [
                "status": "ERROR",
                "finished_reason": "print_timeout",
            ],
        ]
        XCTAssertThrowsError(try state.receive(payload, timeoutSeconds: 180)) { error in
            guard case ProviderError.agyTimedOut(let seconds) = error else {
                return XCTFail("Expected agyTimedOut, got \(error)")
            }
            XCTAssertEqual(seconds, 180)
        }
    }

    func testClaudeCodeStreamEventsEmitBlockBoundaryOnMessageStart() {
        let startLine = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1"}}}"#
        let deltaLine = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#
        if case .blockBoundary = ClaudeCodeCLIProvider.event(in: startLine) {
            // Expected
        } else {
            XCTFail("Expected .blockBoundary on message_start")
        }
        if case .text(let value) = ClaudeCodeCLIProvider.event(in: deltaLine) {
            XCTAssertEqual(value, "Hello")
        } else {
            XCTFail("Expected .text delta")
        }
    }

    // MARK: - SSEParser, ResponsePolicy & OpenAICompatibleProvider

    func testSSEParserHandlesErrorFinishReasonChunkErrorMaxTokensAndArrayError() {
        let chunkError = #"data: {"choices":[{"index":0,"delta":{},"error":{"message":"Provider overloaded"}}]}"#
        XCTAssertEqual(SSEParser.parse(line: chunkError), .failure("Provider overloaded"))

        let errorFinish = #"data: {"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"error"}]}"#
        if case .failure = SSEParser.parse(line: errorFinish) {
            // Expected
        } else {
            XCTFail("Expected .failure on finish_reason=error")
        }

        let maxTokens = #"data: {"choices":[{"index":0,"delta":{"content":"tail"},"finish_reason":"max_tokens"}]}"#
        XCTAssertEqual(SSEParser.parse(line: maxTokens), .outputLimitReached("tail"))

        let geminiArrayError = Data(#"[{"error":{"code":400,"message":"API key not valid."}}]"#.utf8)
        XCTAssertEqual(SSEParser.errorMessage(from: geminiArrayError), "API key not valid.")
    }

    func testResponsePolicySupportsGemini4AndNarrowImageUnsupportedMapping() throws {
        let openRouter = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1/chat/completions"))
        let gemini4Deep = ResponsePolicy.applying(.deep, to: ["model": "google/gemini-4-pro"], endpoint: openRouter)
        XCTAssertEqual((gemini4Deep["reasoning"] as? [String: Any])?["effort"] as? String, "high")

        let geminiOfficial = try XCTUnwrap(URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"))
        let geminiNativeQuick = ResponsePolicy.applying(.quick, to: ["model": "gemini-4-flash"], endpoint: geminiOfficial)
        XCTAssertEqual(geminiNativeQuick["reasoning_effort"] as? String, "low")

        let http400 = HTTPURLResponse(url: openRouter, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
        let genericUnsupported = Data(#"{"error":{"message":"Unsupported parameter: reasoning_effort"}}"#.utf8)
        let mappedGeneric = OpenAICompatibleProvider.mapError(status: 400, data: genericUnsupported, response: http400)
        if case .imageUnsupported = mappedGeneric {
            XCTFail("Unrelated unsupported parameter must not be misclassified as imageUnsupported")
        }

        let visionUnsupported = Data(#"{"error":{"message":"This model does not support image input"}}"#.utf8)
        let mappedVision = OpenAICompatibleProvider.mapError(status: 400, data: visionUnsupported, response: http400)
        if case .imageUnsupported = mappedVision {
            // Expected
        } else {
            XCTFail("Expected .imageUnsupported, got \(mappedVision)")
        }
    }

    func testValidateUsesMaxCompletionTokensOnOfficialOpenAIEndpoint() async throws {
        ValidationCaptureProtocol.lastBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ValidationCaptureProtocol.self]
        let provider = OpenAICompatibleProvider(configuration: configuration)
        let config = ProviderConfig(baseURL: "https://api.openai.com/v1", apiKey: "sk-test", model: "gpt-5", responseMode: .deep)
        try await provider.validate(config: config)
        let body = try XCTUnwrap(ValidationCaptureProtocol.lastBody)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 64)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["reasoning_effort"], "validate probe should stay in standard mode without burning reasoning tokens")
    }

    // MARK: - Context Truncation & Stores

    func testBoundaryTruncationWhereMarkerExceedsDroppedCharsIsReportedAsTruncated() {
        let raw = String(repeating: "a", count: 60_020)
        let truncated = ContextCapture.truncate(raw, limit: 60_000)
        var packet = ContextPacket(appName: "Safari", bundleID: "com.apple.Safari")
        packet.pageText = truncated
        packet.pageTextTotalChars = raw.count
        XCTAssertTrue(packet.isTruncated, "60,020 chars truncated to 60,000 budget must be marked truncated even though marker adds characters")

        let block = PromptBuilder.contextBlock(packet.snapshot(), full: true)
        XCTAssertTrue(block.contains("60,020") || block.contains("60020"))
    }

    @MainActor
    func testConversationStoreArchiveResetAndEphemeralIsolation() throws {
        let suiteName = "WispTests.StoreAudit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("custom-store.json")
        try #"{"version":999,"conversations":[]}"#.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ConversationStore(fileURL: fileURL, settings: settings)
        XCTAssertTrue(store.isReadOnly)
        let ephemeral = store.activateEphemeral(title: "Live Captions")
        XCTAssertTrue(store.isEphemeral(ephemeral.id))

        XCTAssertNotNil(store.archiveBlockingFileAndReset())
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.savedCount, 0, "ephemeralIDs must be cleared so savedCount never goes negative")
        XCTAssertTrue(store.conversations.isEmpty)

        // When activeID is nil and only an ephemeral conversation exists, ensureActive must create a persistent one.
        let ephem2 = store.activateEphemeral(title: "Captions 2")
        store.activeID = nil
        let ensured = try XCTUnwrap(store.ensureActive())
        XCTAssertNotEqual(ensured.id, ephem2.id)
        XCTAssertFalse(store.isEphemeral(ensured.id))
        XCTAssertEqual(settings.lastActiveConversationID, ensured.id.uuidString)

        // Deleting the persistent conversation while an ephemeral one exists must not persist the ephemeral UUID.
        store.delete(ensured.id)
        XCTAssertNil(settings.lastActiveConversationID)
    }

    @MainActor
    func testCorruptBackupPruningSortsNumericallyAcrossCustomStem() throws {
        let suiteName = "WispTests.PruneAudit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("my-history.json")
        for attempt in [1, 2, 9, 10] {
            let backup = dir.appendingPathComponent("my-history.corrupt-1000-\(attempt).json")
            try "corrupt".write(to: backup, atomically: true, encoding: .utf8)
        }
        try "{not-valid-json".write(to: fileURL, atomically: true, encoding: .utf8)

        _ = ConversationStore(fileURL: fileURL, settings: settings)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertEqual(remaining.count, ConversationStore.maxCorruptBackups)
        XCTAssertFalse(remaining.contains("my-history.corrupt-1000-1.json"))
        XCTAssertFalse(remaining.contains("my-history.corrupt-1000-2.json"))
        XCTAssertTrue(remaining.contains("my-history.corrupt-1000-10.json"),
                      "attempt 10 is newer than attempt 9 and must survive numerical pruning")
    }

    @MainActor
    func testQuickCommandStoreRestoreDefaultsMarksCaptionCommandsSeeded() throws {
        let suiteName = "WispTests.QuickCommands.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = QuickCommandStore(defaults: defaults)
        defaults.removeObject(forKey: AppSettings.captionCommandsSeededKey)
        store.restoreDefaults()
        XCTAssertTrue(defaults.bool(forKey: AppSettings.captionCommandsSeededKey))

        // User deletes the caption commands after restoreDefaults; relaunching must respect that deletion.
        store.commands.removeAll { $0.attachedSeconds > 0 }
        let reloaded = QuickCommandStore(defaults: defaults)
        XCTAssertFalse(reloaded.commands.contains { $0.attachedSeconds > 0 })
    }

    // MARK: - Test host

    /// The Debug test host is signed differently from the installed app, so macOS treats it as
    /// another app: a permission prompt or a Keychain access prompt would stall the whole run.
    func testTestHostNeverPromptsAndKeepsItsOwnKeychainItems() {
        XCTAssertTrue(TestHost.isActive, "the XCTest host must be detected, or the launch asks for screen recording")
        XCTAssertEqual(KeychainStore.service, "com.yichenlin.Wisp.tests",
                       "tests must never read or delete the API keys saved by the installed app")
        XCTAssertEqual(Permissions.requestScreenRecording(), Permissions.hasScreenRecording)
    }

    // MARK: - CLICommand

    /// A finished process's exit status is read directly. Waiting for it with `waitUntilExit`
    /// after the awaits inside `run` could block forever on a thread that never receives the
    /// exit notice; the expectation turns such a hang into a failure instead of a stalled run.
    func testFinishedCommandReturnsItsStatusWithoutHanging() async {
        for attempt in 0..<20 {
            let returned = expectation(description: "run returns (attempt \(attempt))")
            let statusBox = StatusBox()
            Task.detached {
                let result = await CLICommand.run("/bin/sh", ["-c", "exit 3"], timeout: 5)
                statusBox.set(result?.status)
                returned.fulfill()
            }
            await fulfillment(of: [returned], timeout: 10)
            XCTAssertEqual(statusBox.value, 3)
        }
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32?
        func set(_ value: Int32?) { lock.withLock { stored = value } }
        var value: Int32? { lock.withLock { stored } }
    }

    // MARK: - Window levels

    /// First-run setup reopened from Settings, and the panel's confirmation alerts, must not sit
    /// under the Settings window, which otherwise stays above the panel. Same path as the
    /// onboarding: a SwiftUI `.sheet` in a KeyablePanel whose delegate is the PanelController.
    @MainActor
    func testPanelRisesAboveSettingsOnlyWhileASheetIsAttached() throws {
        XCTAssertGreaterThan(SettingsWindowPresenter.windowLevel.rawValue, PanelController.level.rawValue)
        XCTAssertGreaterThan(PanelController.askingLevel.rawValue, SettingsWindowPresenter.windowLevel.rawValue)
        XCTAssertLessThan(PanelController.askingLevel.rawValue, NSWindow.Level.popUpMenu.rawValue)

        final class SheetFlag: ObservableObject { @Published var shown = false }
        struct Host: View {
            @ObservedObject var flag: SheetFlag
            var body: some View {
                Color.clear.frame(width: 400, height: 300)
                    .sheet(isPresented: $flag.shown) { Text("fixture").frame(width: 200, height: 100) }
            }
        }
        let flag = SheetFlag()
        let controller = PanelController()
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: PanelController.panelStyleMask, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = PanelController.level
        panel.delegate = controller
        panel.contentView = NSHostingView(rootView: Host(flag: flag))
        defer {
            flag.shown = false
            panel.delegate = nil
            panel.orderOut(nil)
        }
        panel.orderFrontRegardless()

        flag.shown = true
        let opened = Date().addingTimeInterval(3)
        while panel.attachedSheet == nil && Date() < opened {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let sheet = try XCTUnwrap(panel.attachedSheet, "the SwiftUI sheet should attach to the panel")
        XCTAssertEqual(panel.level, PanelController.askingLevel)
        XCTAssertGreaterThan(sheet.level.rawValue, SettingsWindowPresenter.windowLevel.rawValue)

        flag.shown = false
        let closed = Date().addingTimeInterval(3)
        while panel.attachedSheet != nil && Date() < closed {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(panel.attachedSheet)
        XCTAssertEqual(panel.level, PanelController.level)
    }

    /// Settings is above the panel only while it is in use; elsewhere it is an ordinary window, so
    /// System Settings and the panel's popovers are not hidden under it.
    @MainActor
    func testSettingsWindowIsElevatedOnlyWhileInUse() {
        XCTAssertEqual(SettingsWindowPresenter.level(inUse: true), SettingsWindowPresenter.windowLevel)
        XCTAssertEqual(SettingsWindowPresenter.level(inUse: false), .normal)
        XCTAssertGreaterThan(SettingsWindowPresenter.level(inUse: true).rawValue, PanelController.level.rawValue)
        XCTAssertLessThan(SettingsWindowPresenter.level(inUse: false).rawValue, PanelController.level.rawValue)
    }

    /// The panel floats; asking something puts it above Settings; first-run setup steps back while
    /// the user is in another app (granting a permission), confirmation alerts do not.
    @MainActor
    func testPanelLevelRules() {
        for inUse in [true, false] {
            XCTAssertEqual(PanelController.level(sheetAttached: false, onboarding: false, inUse: inUse), .floating)
            XCTAssertEqual(PanelController.level(sheetAttached: true, onboarding: false, inUse: inUse),
                           PanelController.askingLevel)
        }
        XCTAssertEqual(PanelController.level(sheetAttached: true, onboarding: true, inUse: true), PanelController.askingLevel)
        XCTAssertEqual(PanelController.level(sheetAttached: true, onboarding: true, inUse: false), .normal)
    }

    /// Changing a window's level takes its sheet along; a sheet left behind would sit under it.
    @MainActor
    func testLevelChangeMovesTheAttachedSheetToo() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer {
            if window.attachedSheet != nil { window.endSheet(sheet) }
            window.orderOut(nil)
        }
        window.orderFrontRegardless()
        window.beginSheet(sheet)
        let attached = Date().addingTimeInterval(3)
        while window.attachedSheet == nil && Date() < attached {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(window.attachedSheet === sheet)

        WindowLevelCoordinator.apply(PanelController.askingLevel, to: window)
        XCTAssertEqual(window.level, PanelController.askingLevel)
        XCTAssertEqual(sheet.level, PanelController.askingLevel)
        WindowLevelCoordinator.apply(.normal, to: window)
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(sheet.level, .normal)
    }

    // MARK: - Shortcuts, Audio Sink, Live Captions & Markdown

    @MainActor
    func testAdvancedShortcutStandaloneModifierIgnoresChordsAndCapsLock() throws {
        let monitor = AdvancedShortcutMonitor()

        // Left and Right Shift normalize to the same canonical Candidate.
        let leftShift = AdvancedShortcut(keyCode: UInt16(kVK_Shift), kind: .modifier)
        let rightShift = AdvancedShortcut(keyCode: UInt16(kVK_RightShift), kind: .modifier)
        XCTAssertEqual(AdvancedShortcutMonitor.Candidate(leftShift), AdvancedShortcutMonitor.Candidate(rightShift))

        // Shift down -> A down -> Shift up must NOT produce a standalone Shift candidate.
        let shiftDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 1.0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Shift)))
        let aDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 1.05,
            windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
        let shiftUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 1.1,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Shift)))

        XCTAssertNil(monitor.candidate(for: shiftDown))
        XCTAssertNil(monitor.candidate(for: aDown))
        XCTAssertNil(monitor.candidate(for: shiftUp), "Shift+A must not trigger standalone Shift on release")

        // A clean Shift tap immediately afterwards MUST produce the standalone Shift candidate.
        XCTAssertNil(monitor.candidate(for: shiftDown))
        XCTAssertEqual(monitor.candidate(for: shiftUp), AdvancedShortcutMonitor.Candidate(leftShift))

        // Typing plain keys and then tapping a lone modifier: the very first tap must count,
        // otherwise a double-tap shortcut needs three presses after typing.
        let plainKeyDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1.2,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_A)))
        let controlDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.control], timestamp: 1.3,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Control)))
        let controlUp = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 1.35,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Control)))
        let control = AdvancedShortcutMonitor.Candidate(AdvancedShortcut(keyCode: UInt16(kVK_Control), kind: .modifier))
        XCTAssertNil(monitor.candidate(for: plainKeyDown))
        XCTAssertNil(monitor.candidate(for: controlDown))
        XCTAssertEqual(monitor.candidate(for: controlUp), control, "the first lone tap after typing must count")

        // Holding Control and tapping Option is a chord: neither release is a lone tap.
        let controlOptionDown = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.control, .option], timestamp: 1.4,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Option)))
        let optionUpControlHeld = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.control], timestamp: 1.45,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Option)))
        XCTAssertNil(monitor.candidate(for: controlDown))
        XCTAssertNil(monitor.candidate(for: controlOptionDown))
        XCTAssertNil(monitor.candidate(for: optionUpControlHeld))
        XCTAssertNil(monitor.candidate(for: controlUp), "releasing the last key of a chord is not a lone tap")

        // Caps Lock active must not pollute normal key-chord matching (e.g. Shift+Space).
        let shiftSpaceWithCaps = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [.shift, .capsLock], timestamp: 2.0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: UInt16(kVK_Space)))
        let expectedShiftSpace = AdvancedShortcut(keyCode: UInt16(kVK_Space), kind: .key, modifiers: [.shift])
        XCTAssertEqual(monitor.candidate(for: shiftSpaceWithCaps), AdvancedShortcutMonitor.Candidate(expectedShiftSpace))
    }

    func testListeningAudioSinkConcurrentOverflowAndImmediateReleaseDoesNotTrap() throws {
        final class SlowFeed: SpeechFeed {
            var isDrained = true
            func append(_ buffer: AVAudioPCMBuffer) { Thread.sleep(forTimeInterval: 0.005) }
            func endAudio() {}
            func cancel() {}
        }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160

        final class FailureCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let failures = FailureCounter()
        do {
            let queue = ListeningAudioSink.makeQueue()
            let sink = ListeningAudioSink(feed: SlowFeed(), queue: queue) { _ in failures.increment() }
            DispatchQueue.concurrentPerform(iterations: 80) { _ in
                sink.enqueue(buffer)
            }
            // Drop `sink` immediately while queued items are still in flight: previously this
            // trapped in `_dispatch_semaphore_dispose` when `DispatchSemaphore` count < initial value.
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertLessThanOrEqual(failures.count, 1)
    }

    /// Releasing push-to-talk: chunks already queued are the last words, so they reach the
    /// recognizer before the end of audio. Cancel still drops them.
    func testListeningAudioSinkFinishDeliversQueuedChunksBeforeEndingAudio() throws {
        final class RecordingFeed: SpeechFeed, @unchecked Sendable {
            private let lock = NSLock()
            private var log: [String] = []
            var isDrained = true
            var events: [String] { lock.withLock { log } }
            func append(_ buffer: AVAudioPCMBuffer) {
                Thread.sleep(forTimeInterval: 0.01)
                lock.withLock { log.append("append") }
            }
            func endAudio() { lock.withLock { log.append("end") } }
            func cancel() { lock.withLock { log.append("cancel") } }
        }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        let chunks = 8
        XCTAssertLessThan(chunks, ListeningAudioSink.maxBufferedChunks)

        let finishing = RecordingFeed()
        let finishSink = ListeningAudioSink(feed: finishing, queue: ListeningAudioSink.makeQueue()) { _ in }
        for _ in 0..<chunks { finishSink.enqueue(buffer) }
        finishSink.finish()
        finishSink.enqueue(buffer)
        finishSink.queue.sync {}
        XCTAssertEqual(finishing.events, Array(repeating: "append", count: chunks) + ["end"])

        let cancelling = RecordingFeed()
        let cancelSink = ListeningAudioSink(feed: cancelling, queue: ListeningAudioSink.makeQueue()) { _ in }
        for _ in 0..<chunks { cancelSink.enqueue(buffer) }
        cancelSink.cancel()
        cancelSink.queue.sync {}
        XCTAssertLessThan(cancelling.events.filter { $0 == "append" }.count, chunks)
        XCTAssertEqual(cancelling.events.last, "cancel")
    }

    @MainActor
    func testLiveCaptionsIdleIgnoresSleepNotification() {
        let captions = LiveCaptions.shared
        guard !captions.isActive else { return }
        let previousMessage = captions.message
        defer {
            if previousMessage == nil { captions.dismissMessage() }
        }
        captions.dismissMessage()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(captions.message)
    }

    func testMarkdownBlockHandlesCRLFMismatchedFencesAndOpenEmptyCodeFence() {
        let fenced = MarkdownBlock.parse("```swift\r\n~~~\r\nlet x = 1\r\n```")
        XCTAssertEqual(fenced.count, 1)
        if case .code(let language, let text) = fenced.first {
            XCTAssertEqual(language, "swift")
            XCTAssertEqual(text, "~~~\nlet x = 1")
        } else {
            XCTFail("Expected single fenced code block")
        }

        let openEmpty = MarkdownBlock.parse("```python")
        XCTAssertEqual(openEmpty.count, 1)
        if case .code(let language, let text) = openEmpty.first {
            XCTAssertEqual(language, "python")
            XCTAssertEqual(text, "")
        } else {
            XCTFail("Expected open empty code block during streaming")
        }
    }
}

private final class ValidationCaptureProtocol: URLProtocol {
    nonisolated(unsafe) static var lastBody: [String: Any]?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf.prefix(n))
            }
        }
        Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

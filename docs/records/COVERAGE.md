# Wisp Audit — Round-2 Coverage

Every Swift file in the repo read end-to-end (dev probes under `tools/screen-privacy/` read, with measurement-machinery tails skimmed — marked per row). Function counts are mechanical (`grep -c "func "`, which also catches the word in a few comments/strings; reconciled against the reading — no file's count disagreed with what the read found by more than that noise). Verdicts: **clean** = no new issue beyond what AUDIT-FIXES.md / AUDIT-ROUND2.md already track.

**Totals: 82 files · 21717 lines · 823 `func ` occurrences.** App target 63 files (62 pre-existing + NotesPanel.swift added in round 3), tests 13 (8 pre-existing + 5 added in round 2), tools 6.

| File | Lines | funcs | Verdict |
|---|---:|---:|---|
| `Wisp/App/AppDelegate.swift` | 292 | 8 | finding #29 — stale update-check privacy comment (fixed `84e448c`); otherwise clean |
| `Wisp/App/WispApp.swift` | 113 | 2 | clean |
| `Wisp/Capture/BrowserTextExtractor.swift` | 475 | 14 | clean |
| `Wisp/Capture/ChromeProfileInspector.swift` | 111 | 4 | clean |
| `Wisp/Capture/ContextCapture.swift` | 308 | 12 | clean |
| `Wisp/Capture/ContextPacket.swift` | 122 | 4 | clean |
| `Wisp/Capture/PageTextScript.swift` | 256 | 1 | clean |
| `Wisp/Capture/ScreenCapturer.swift` | 174 | 5 | clean |
| `Wisp/Capture/ScrollDriver.swift` | 96 | 6 | clean |
| `Wisp/LLM/AgyCLIProvider.swift` | 406 | 16 | clean |
| `Wisp/LLM/ChatProvider.swift` | 396 | 17 | clean |
| `Wisp/LLM/ClaudeCodeCLIProvider.swift` | 402 | 12 | clean |
| `Wisp/LLM/CloudProvider.swift` | 192 | 1 | clean |
| `Wisp/LLM/CodexCLIProvider.swift` | 463 | 14 | finding #28 — hardcoded client version (fixed `eeb8dbd`); otherwise clean |
| `Wisp/LLM/ModelCatalog.swift` | 76 | 4 | clean |
| `Wisp/LLM/OllamaSupport.swift` | 75 | 3 | clean |
| `Wisp/LLM/OpenAICompatibleProvider.swift` | 336 | 12 | finding #30 — per-request URLSession (proposal); otherwise clean (round-2 #10 caps here) |
| `Wisp/LLM/PromptBuilder.swift` | 151 | 4 | clean |
| `Wisp/LLM/ProviderKind.swift` | 61 | 0 | clean |
| `Wisp/LLM/ResponsePolicy.swift` | 123 | 4 | clean |
| `Wisp/LLM/SSEParser.swift` | 100 | 5 | clean |
| `Wisp/Listening/ListeningCapture.swift` | 227 | 10 | clean |
| `Wisp/Listening/ListeningModel.swift` | 429 | 19 | clean |
| `Wisp/Listening/ListeningSpeechTrack.swift` | 222 | 9 | clean |
| `Wisp/Listening/ListeningTranscript.swift` | 329 | 16 | clean |
| `Wisp/Listening/LocalSpeechCatalog.swift` | 148 | 13 | clean |
| `Wisp/Listening/LocalSpeechFamilies.swift` | 62 | 4 | clean |
| `Wisp/Listening/LocalSpeechModel.swift` | 103 | 8 | clean |
| `Wisp/Listening/LocalSpeechRecognition.swift` | 155 | 7 | clean |
| `Wisp/Listening/ONNXModelInfo.swift` | 104 | 6 | clean |
| `Wisp/Listening/PushToTalk.swift` | 183 | 9 | clean |
| `Wisp/Store/Conversation.swift` | 237 | 4 | clean |
| `Wisp/Store/ConversationStore.swift` | 267 | 17 | clean |
| `Wisp/Store/KeychainStore.swift` | 88 | 10 | clean |
| `Wisp/Store/QuickCommandStore.swift` | 121 | 7 | clean |
| `Wisp/Support/AdvancedShortcut.swift` | 435 | 16 | clean |
| `Wisp/Support/AppLifecycle.swift` | 199 | 8 | finding #31 — AppLanguage has no zh-Hant case (proposal); UpdateChecker clean (round-2 #14 here) |
| `Wisp/Support/AppSettings.swift` | 573 | 8 | clean |
| `Wisp/Support/LocalCursorController.swift` | 375 | 23 | clean |
| `Wisp/Support/Permissions.swift` | 49 | 8 | clean |
| `Wisp/Support/ScreenGeometry.swift` | 83 | 4 | clean |
| `Wisp/Support/ScreenPrivacy.swift` | 91 | 7 | clean |
| `Wisp/UI/AssistantModel.swift` | 641 | 40 | clean |
| `Wisp/UI/ChatInput.swift` | 171 | 9 | clean |
| `Wisp/UI/ChatView.swift` | 519 | 0 | clean |
| `Wisp/UI/ContextHeaderView.swift` | 268 | 2 | clean |
| `Wisp/UI/ConversationListView.swift` | 247 | 1 | clean |
| `Wisp/UI/DesignKit.swift` | 250 | 7 | clean |
| `Wisp/UI/IslandController.swift` | 244 | 15 | clean |
| `Wisp/UI/IslandLayout.swift` | 104 | 8 | clean |
| `Wisp/UI/IslandModel.swift` | 69 | 2 | clean |
| `Wisp/UI/IslandRenderer.swift` | 222 | 8 | clean |
| `Wisp/UI/IslandView.swift` | 331 | 3 | clean |
| `Wisp/UI/ListeningView.swift` | 286 | 1 | clean |
| `Wisp/UI/MarkdownText.swift` | 441 | 13 | clean |
| `Wisp/UI/ModelSwitcher.swift` | 290 | 16 | clean |
| `Wisp/UI/NotesPanel.swift` | 165 | 11 | clean |
| `Wisp/UI/PanelController.swift` | 412 | 25 | clean |
| `Wisp/UI/PanelResize.swift` | 240 | 16 | clean |
| `Wisp/UI/QuickCommandSettingsView.swift` | 99 | 1 | clean |
| `Wisp/UI/ResponseModeView.swift` | 228 | 2 | clean |
| `Wisp/UI/SettingsView.swift` | 1976 | 16 | clean |
| `Wisp/UI/TranscriptView.swift` | 170 | 2 | clean |
| `WispTests/CLIJSONLinesTests.swift` | 70 | 8 | clean |
| `WispTests/CStringPoolTests.swift` | 49 | 6 | clean |
| `WispTests/CaptureScopeTests.swift` | 93 | 5 | clean |
| `WispTests/ClaudeCodeCLIProviderTests.swift` | 540 | 43 | clean |
| `WispTests/DrainBufferTests.swift` | 57 | 6 | clean |
| `WispTests/ListeningTests.swift` | 914 | 51 | clean |
| `WispTests/LocalCursorTests.swift` | 347 | 15 | clean |
| `WispTests/LocalSpeechTests.swift` | 459 | 28 | clean |
| `WispTests/NonAudioAcceptanceTests.swift` | 241 | 12 | clean |
| `WispTests/ProviderSharedTests.swift` | 51 | 5 | clean |
| `WispTests/QuickCommandTests.swift` | 61 | 4 | clean |
| `WispTests/ResponseModeTests.swift` | 467 | 26 | clean |
| `WispTests/StreamGuardTests.swift` | 118 | 14 | clean |
| `tools/non-audio/ExportPageScripts.swift` | 11 | 1 | clean |
| `tools/screen-privacy/CaptureMatrixProbe.swift` | 327 | 6 | clean — dev probe (read; tail skimmed) |
| `tools/screen-privacy/LocalCursorProbe.swift` | 487 | 12 | clean — dev probe (read; tail skimmed) |
| `tools/screen-privacy/Probe.swift` | 248 | 7 | clean |
| `tools/screen-privacy/SurfaceProbe.swift` | 347 | 8 | clean — dev probe (read; tail skimmed) |
| `tools/screen-privacy/VNCFrameProbe.swift` | 249 | 7 | clean — dev probe (read; tail skimmed) |

## New findings from this pass

- **#28** Codex app-server handshake hardcoded client version `0.4.0` (`Wisp/LLM/CodexCLIProvider.swift`) — **fixed** `eeb8dbd`, test `CodexClientInfoTests`.
- **#29** Third copy of the false "no identifying information" update-check claim (`Wisp/App/AppDelegate.swift`) — **fixed** `84e448c` (comment).
- **#30** Cloud provider constructs a fresh `URLSession` per question (`Wisp/LLM/OpenAICompatibleProvider.swift` + `ProviderConfig.provider(for:)`) — **proposal** (shared session), needs Mac verification of cancellation semantics.
- **#31** `AppLanguage` (in `Wisp/Support/AppLifecycle.swift`) offers system / English / zh-Hans only — after #9 the app ships zh-Hant strings, and system-following users get them, but the in-app pin cannot select Traditional. **Proposal:** add `case traditionalChinese = "zh-Hant"` with literal title "繁體中文" (matching the unlocalized "简体中文"/"English" pattern) once the #9 draft passes native review. Not landed: it is a user-facing string decision tied to that review.

## Dependency inventory (Package.resolved — 3 pins)

| Package | Version | Declared in project.yml | Imported by | Purpose | Pinning |
|---|---|---|---|---|---|
| KeyboardShortcuts (sindresorhus) | 2.4.0 | `exactVersion: 2.4.0` (round-2 #22; was `from: 2.2.1`) | AppDelegate, WispApp, QuickCommandStore, IslandView, QuickCommandSettingsView, ResponseModeView, SettingsView | Global hotkeys + recorder UI | Exact — consistent with resolved |
| sherpa-onnx (k2-fsa) | 1.13.7 | `exactVersion: 1.13.7` | LocalSpeechFamilies, LocalSpeechModel, LocalSpeechRecognition | On-device speech recognition (SenseVoice / Qwen3-ASR) | Exact — consistent |
| onnxruntime-libs | 1.28.1 | — (transitive, via sherpa-onnx) | no direct imports | ONNX runtime binaries sherpa-onnx links against | Managed upstream; nothing to pin locally |

## Test-target audit (WispTests)

Pre-existing: 8 files, 146 test methods, ~640 assertions (ListeningTests alone: 45 tests / 194 assertions; ClaudeCodeCLIProviderTests: 35 / 116; ResponseModeTests: 21 / 107). Round 2 added 5 files / 38 test methods (StreamGuard 13, CLIJSONLines 8, CStringPool 6, DrainBuffer 6, ProviderShared 5 incl. #28).

- **Disabled tests:** none. No `XCTSkip` except one environment gate: `LocalSpeechTests` skips a real-model test when no local speech model is installed on the test machine — legitimate and self-describing.
- **Addendum (post-coverage, from the Linux harness run):** executing the suite surfaced one environment-sensitive test the static pass could not: `CLIPromptTests.testOversizedPromptIsTruncated` passes only when the truncation marker resolves in English — promoted to finding **#32** in `AUDIT-ROUND2.md` (root-caused numerically; fix is a product decision, not landed).
- **Empty / trivially-passing tests:** none found — no `XCTAssertTrue(true)`, no assertion-free test bodies; the acceptance file (`NonAudioAcceptanceTests`) runs real store round-trips against temp directories, including a check that streaming deltas do not rewrite the history file.
- **Honest gaps:** UI/AppKit behaviour (panels, cursor, island) is covered by the `tools/screen-privacy` probe suite + `LocalCursorTests` rather than by CI-runnable tests of the views themselves; `LocalSpeechTests`' real-model path only runs on a machine with models installed. Both are environmental, not neglect.

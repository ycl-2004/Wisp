# Wisp Linux Harness — verification scaffold (NOT part of the shipped app)

A SwiftPM package that compiles the Foundation-only closure of Wisp's app
sources and runs the matching subset of `WispTests` against them. It exists
for machines without Xcode (the Linux cloud agents) and, on a Mac, to run the
core tests without `xcodebuild test` launching the app as its test host.

- Not referenced by `project.yml`; never built by Xcode or the macOS CI.
- Lives under lowercase `tools/` with the repo's other dev tools (the
  brief suggested `Tools/LinuxHarness/`; on case-insensitive APFS that
  would collide with the existing `tools/` directory).

## Run it

```sh
# Linux: export PATH=$HOME/swift-toolchain/swift-6.2/usr/bin:$PATH   (Swift 6.2, Ubuntu 24.04)
./sync-sources.sh        # copy app sources and test files, extract pure functions
swift test               # build + run
```

The module is named `Wisp`, so test files compile verbatim
(`@testable import Wisp`). `Sources/Wisp/*.swift` (except `HarnessShims.swift`)
and everything under `Tests/` are copies made by the sync and are git-ignored;
re-run the sync after any app or test change.

## The closure (23 app files, verbatim)

All of `Wisp/LLM` (13), `Wisp/Capture/{BrowserTextExtractor,
ChromeProfileInspector, ContextPacket, PageTextScript}`,
`Wisp/Store/{Conversation, ConversationStore}`,
`Wisp/Listening/{ListeningTranscript, ONNXModelInfo}`,
`Wisp/Support/{AppSettings, OnboardingReadiness}`.

Excluded, with reasons:
- `LocalSpeechCatalog` / `LocalSpeechModel` / `LocalSpeechFamilies` /
  `LocalSpeechRecognition` — the model/family types wrap sherpa-onnx C
  config builders (the CStringPool fix, #25, therefore stays CI-pending).
- `KeychainStore` — Security framework (shimmed, below).
- Everything AppKit/SwiftUI/ScreenCaptureKit — by definition.

Plus two *mechanically extracted* pure-function families, re-extracted
verbatim from the app files on every sync by
`extract-context-capture.py` (brace-matched, by name — no hand copies):
`ContextCapture.truncate` + its 4 helpers, and
`ScreenCapturer.maxLongEdge` / `displayIndex`.

## Shims (all in `Sources/Wisp/HarnessShims.swift`, harness-only)

No app source was edited for this harness. Platform gaps are covered
here, each with its fidelity limit:

| Shim | Why | Fidelity |
|---|---|---|
| `@_exported import FoundationNetworking` | URLSession lives there on Linux | Full |
| `ObservableObject` / `@Published` / `objectWillChange` | Combine absent from Linux Foundation | Compiles + logic runs; change notifications are no-ops (no test here asserts them) |
| `String(localized:)` + `LocalizedStringValue` | Absent from Linux Foundation | Returns the source string with interpolations — same as a missing catalog key on macOS. Language-dependent results are NOT verified (and see finding #32: one test's outcome depends on this) |
| `KeychainStore` (in-memory) | Security framework | `authorized()` behaves as with an empty Keychain |
| `UpdateChecker.currentVersion` / `userAgent` | Real one is in an AppKit file | Accessors mirrored byte-for-byte (bundle lookup + "0" fallback); ported tests pin the *callers'* wiring against it |
| `URLSession.bytes(for:)` | Absent from Linux Foundation | Same shape, backed by a whole-response data task — bytes are not incremental. The provider's loop logic runs verbatim (incl. the URLProtocol-driven priority-retry test) |
| `ScrollDriver` (inert, untrusted) | CGEvent/AppKit | Extractor takes its no-scroll path; actuation untestable here |
| `ShortcutTriggerMode` / `AdvancedShortcut` | Real ones are in an AppKit/Carbon file | Raw values + Codable fields mirrored exactly (AppSettings treats them opaquely) |
| `LocalSpeechCatalog.legacySenseVoiceID` | Real class is sherpa-bound | One mirrored constant; sync asserts the upstream value, drift fails the sync |
| `ScreenCapturer.tinyTestJPEG` (extension) | CoreGraphics/ImageIO | Returns minimal JPEG framing bytes; tests only require non-nil |

One documented line-drop in the *copied* file only: the sync deletes
`config.waitsForConnectivity = false` from the Linux copy of
`OpenAICompatibleProvider.swift` — the property is get-only-and-false on
Linux, so the assignment cannot compile and dropping it preserves the
exact semantics. The macOS source is untouched, and the sync fails
loudly if the upstream line disappears.

## Tests (copied from `../../WispTests`)

There are no harness-only tests and no ported copies: `sync-sources.sh` copies
the `WispTests` files listed in its `TEST_FILES` array into `Tests/WispTests/`
verbatim. A test is written and edited in `WispTests` only.

To keep that possible, every `WispTests` file is either entirely portable or
entirely macOS-only. A file with AppKit, SwiftUI, AVFoundation, JavaScriptCore or
sherpa-onnx subjects is not listed; when a file mixes both, split it (as
`ResponseModeTests` / `ResponseModeUITests`, `ListeningTranscriptTests` /
`ListeningTests`, `ConversationAcceptanceTests` / `NonAudioAcceptanceTests`) rather
than adding `#if` branches. Tests whose subjects are `@MainActor` keep nonisolated
entry points and hop in through `onMainActor` (`WispTests/MainActorBridge.swift`),
because swift-corelibs-xctest traps when it discovers a `@MainActor` test.

Before 2026-11-18 the harness kept its own hand-ported copies in
`Tests/WispCoreTests/`; 26 of 28 had drifted from `WispTests`, and the round-6
end-to-end suites existed only here, so macOS CI never ran them. Those suites now
live in `WispTests` and run in both places.

## Results

2026-11-18, macOS (Swift 6.4, Xcode 27.2): **254 tests, 0 failures, 6 skipped**
(three need a real Ollama via `OLLAMA_E2E`; three skip because a real `claude`,
`codex` and `agy` are installed, which the missing-binary tests would otherwise
fall back to and run). The Linux run of this layout has not been repeated since
the restructure.

### 2026-11-02, Linux audit VM, Swift 6.2 (historical, previous layout)

**98 tests executed, 96 passed, 2 failed** (21 s). 18 suites; 16 fully
green. The two failures, both diagnosed to root cause:

1. `CLIPromptTests.testOversizedPromptIsTruncated` — **real finding
   (#32)**: the test's slack (budget + 100 tokens) is smaller than the
   Chinese truncation marker's token cost (~107 by the app's own
   estimator), so it passes only when the marker resolves in English
   (~93). `CLIPrompt.fit` does one proportional pass and never accounts
   for the marker it appends. On a zh-Hans/zh-Hant macOS host this
   WispTests case would fail the same way; macOS CI is English-locale.
2. `CaptureScopeTests.testExcludedAppsAreAlwaysHiddenFromWholeScreenCaptures`
   — platform artifact: the test unwraps `Bundle.main.bundleIdentifier`,
   which is nil for a SwiftPM test binary (the macOS suite runs inside
   the app host). Not an app-code failure.

Round-2 fixes whose tests ran green here (status upgraded from
CI-pending to **Linux-verified**; macOS CI still pending):
#10 (SSE splitter + capped buffer suites, and the provider streaming
loop via the URLProtocol priority-retry test), #11 (DrainBuffer),
#13 (CLIWallClock), #27 (CLIJSONLines). #14/#28's derivation *wiring*
verified against the mirrored `UpdateChecker` accessors. #25 remains
CI-pending only.

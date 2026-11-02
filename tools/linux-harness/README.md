# Wisp Linux Harness — verification scaffold (NOT part of the shipped app)

A SwiftPM package that compiles the Foundation-only closure of Wisp's app
sources on Linux and runs ported unit tests against them for real. It
exists because the audit VM has no macOS toolchain: this is the one place
round-2 fixes could be *executed*, not just inspected.

- Not referenced by `project.yml`; never built by Xcode or the macOS CI.
- Lives under lowercase `tools/` with the repo's other dev tools (the
  brief suggested `Tools/LinuxHarness/`; on case-insensitive APFS that
  would collide with the existing `tools/` directory).

## Run it

```sh
export PATH=$HOME/swift-toolchain/swift-6.2/usr/bin:$PATH   # Swift 6.2, Ubuntu 24.04
./sync-sources.sh        # copy app sources + extract pure functions (see below)
swift test               # build + run
```

`Sources/WispCore/*.swift` (except `HarnessShims.swift`) are build
artifacts copied from `../../Wisp` and are git-ignored; re-run the sync
after any app change.

## The closure (21 app files, verbatim)

All of `Wisp/LLM` (12), `Wisp/Capture/{BrowserTextExtractor,
ChromeProfileInspector, ContextPacket, PageTextScript}`,
`Wisp/Store/{Conversation, ConversationStore}`,
`Wisp/Listening/{ListeningTranscript, ONNXModelInfo}`,
`Wisp/Support/AppSettings`.

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

## Shims (all in `Sources/WispCore/HarnessShims.swift`, harness-only)

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

## Ported tests (in `Tests/WispCoreTests/`)

Verbatim except the noted trims; every trim is also commented at the top
of its file. Dropped tests still run on macOS CI.

- Round-2 fix tests, complete: `StreamGuardTests` (13),
  `DrainBufferTests` (6), `CLIJSONLinesTests` (8), `ProviderSharedTests`
  (5 — CLIWallClock ×2, UserAgent ×2, CodexClientInfo ×1).
- `ClaudeCodeCLIProviderTests.swift` collection (CLIStreaming,
  PrivacyTransport, ClaudeCode, CLIPrompt, CLITemporaryDirectory,
  BrowserPrivacy, SpeedPreference): dropped `AdvancedShortcutTests`
  (Carbon) and `MarkdownBlockTests` (SwiftUI file), unused imports.
- `ResponseModeTests`: 12 of 21 kept; dropped render tests and the ones
  whose subjects (`AssistantModel`, `ActiveModels`) live in SwiftUI
  files.
- `CaptureScopeTests`: all 5.
- `NonAudioAcceptanceTests`: the 4 ConversationStore tests; the 5
  AppKit/SwiftUI tests dropped. Its `@MainActor` bodies are bridged —
  swift-corelibs-xctest's discovery cast traps on @MainActor test
  methods, so the original bodies run as private impls behind thin
  wrappers (assertions byte-identical).
- `ListeningTranscriptPortTests`: 15 of 45 from `ListeningTests` (the
  transcript/preferences/storage-budget subjects); one XCTAttachment
  measurement note dropped (no XCTAttachment in corelibs-xctest; no
  assertion affected).

Not ported: `CStringPoolTests` (#25's file is outside the closure),
`LocalCursorTests`, `LocalSpeechTests`, `QuickCommandTests` — subjects
are AppKit/SwiftUI/sherpa/KeyboardShortcuts-bound.

## Results (2026-11-02, this VM, Swift 6.2)

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

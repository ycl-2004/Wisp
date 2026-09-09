# Screen Privacy Validation — 2026-09-07

## Goal
Test and improve Wisp's screen-capture hiding while preserving local use; verify the target browser/proctoring context before claiming it is hidden there.

## Requirements (append-only)
1. Inspect the existing hiding implementation and capture boundaries. Completed.
2. Run capture comparisons and regression checks. Native mechanism checks and one real browser/display capture path completed; broader UI and third-party coverage remains scoped out.
3. Fix relevant code and misleading documentation. Completed and built in Debug and Release.
4. Ensure no Wisp surface appears in the target recording while Wisp remains usable. Established for the installed panel on the current display and the local Chrome `getDisplayMedia` test; not a CodeSignal verdict and not full-surface coverage.
5. Audit Chrome-side residual state and prevent Wisp-specific page residue. Static/profile audit completed; non-scrolling extraction now clears `window.__wispCollector`, with a regression test.

## Decisions
- Preserve the locally effective legacy sharingType flag; Apple's warning does not imply failure in every environment.
- Add a settings-view attachment hook rather than relying only on later update notifications.
- Treat window enumeration, captured pixels, and third-party integrity signals as separate observations.
- Use synthetic windows with the production ScreenPrivacy source and isolated in-memory settings; no model providers, personal preferences, or real assessments are used.
- Keep existing appearance and interaction; UI edits clarify the hiding request and limits.
- Existing completed UI review archived verbatim in history.md. This task is retained because target-browser verification remains open and may need resuming.

## Evidence
- docs/screen-privacy-validation.md: scope, results, constraints, and reproduction commands.
- docs/evidence/screen-privacy-20260907.json: raw statistics from both final capture runs.
- On macOS 26.6.1, all 3 fixture windows: visible group 21/21 frames with marker; hidden group 0/21 frames with marker. ScreenCaptureKit and system screenshots agree.
- ScreenCaptureKit still enumerates 3/3 windows in both states.
- Eight lifecycle checks pass, including setting the flag before the attached window is shown and preserving input, frame, and visibility across toggles.
- Existing XCTest suite plus browser-residue regression: 15 passed, 0 failed, 0 skipped. Result: /private/tmp/wisp-privacy-tests-20260907-r3.xcresult.
- Debug and Release builds exit 0 with CODE_SIGNING_ALLOWED=NO.
- JSON validation, browser-script syntax check, and git diff --check pass.
- Reinstalled `/Applications/Wisp.app` from the rebuilt and ad-hoc re-signed Debug bundle; bundle id `com.yichenlin.Wisp`, version `0.3.0 (5)`, executable comparison and strict codesign verification pass. Earlier bundles remain recoverable under `/private/tmp/Wisp.app.backup-before-privacy-20260907` and `/private/tmp/Wisp.app.backup-before-cleanup-20260907`.
- Real installed panel test: `SCShareableContent` listed one on-screen Wisp window (`sharingState=0`) while the cropped screenshot and 10 captured stream frames showed only underlying content. The same local Chrome screen-share page showed the A/B contrast: Wisp content appeared with hiding disabled and disappeared after restoring the flag.
- Real installed settings and island tests: settings window (620×608 points) and island window (372×76 points) were each on-screen with `sharingState=0`; one screenshot crop plus 10 stream frames per window showed only underlying content. Their original preference state was restored afterward (`showIsland=false`, `hideFromScreenCapture=true`).
- Read-only Chrome profile audit found zero files containing Wisp-specific markers (`com.yichenlin.Wisp`, `hideFromScreenCapture`, `wisp-screen-privacy`, `WispCaptureProbe`) outside excluded large cache directories. Static code review found Chrome profile reads but no writes.
- Browser residue fix: `PageTextScript.cleanupJS` clears the temporary page collector on non-scrolling and ordinary page-text paths; the full XCTest run now reports 15 passed, 0 failed, 0 skipped.
- Window-level `screencapture -l` for the protected Wisp window exited 1 without creating an image; this is additional evidence of pixel protection, not proof of invisibility to every recorder.

## Outstanding
- The first automated Chrome attempts returned `InvalidStateError`, but the persistent local page later obtained a real 3024×1964 `displaySurface=monitor` stream. The page itself is not CodeSignal and does not exercise CodeSignal telemetry or human review.
- System authorization dialogs, animation/Space transitions, multiple displays, and third-party recorder compatibility remain unverified. Settings and island pixel paths are now covered on the current display.
- The installed bundle reports `com.yichenlin.Wisp`, version `0.3.0 (5)`; its executable matches `Build/Debug/Wisp.app/Contents/MacOS/Wisp`, and `codesign --verify --deep --strict` passes. Nothing was committed or published.

## Current extension: end-to-end privacy audit — 2026-09-07

Goal: audit invocation, capture, extraction, API/CLI transport, storage and cleanup; harden Wisp-controlled leakage while keeping the accepted full-display fallback and normal usage.

Requirements (append-only):
6. Inventory network, logs, browser/CDP and local-process exposure from invocation through answer.
7. Reduce unnecessary networking and persistent HTTP state; protect local storage and diagnostic entry points.
8. Verify changed behavior using synthetic data, without invoking model CLIs or sending personal screen content.
9. Explain residual same-user/admin, OS, browser, sharing, provider, backup and CLI limits; do not promise invisibility or zero risk.
10. (Added during validation) Keep the build and screenshot documentation consistent with the new
    diagnostics gate, since `--render-*` also moved behind `WISP_DIAGNOSTICS`. Completed.

Decisions:
- No Claude CLI access or credential/session inspection. Provider source and pure tests only.
- Existing screen-sharing tests remain historical evidence, not fresh Zoom validation.
- Direct API sessions become ephemeral with no cookies/cache/credential store and no redirects; canonical endpoints must be configured explicitly.
- New installs default automatic update checks off; existing explicit preferences are preserved.
- Private storage directory permissions exclude other local accounts, not processes running as the same user.
- Debug capture/remote-show entry points require a separate WISP_DIAGNOSTICS build flag, absent from standard builds.

Validation (2026-09-07):
- Full XCTest suite: 20 passed, 0 failed, 0 skipped, including the new 5-test `PrivacyTransportTests`.
  Result bundle: /private/tmp/wisp-privacy-e2e-20260907.xcresult. Synthetic endpoints and directories
  only; no model CLI was invoked and no real screen content was sent.
- Transport assertions cover HTTPS enforcement with loopback HTTP still allowed, rejected remote HTTP,
  LAN IPs, embedded credentials and query strings, nil cache/cookie/credential stores, a refused 307
  redirect, and a `URLProtocol`-intercepted validate call that reached only the configured endpoint
  with no Cookie or Referer header.
- Storage test creates a `0755` directory with a file, then confirms `0700` and unchanged contents.
  The real support directory on this machine is `drwx------`.
- Debug and Release builds exit 0 with `CODE_SIGNING_ALLOWED=NO`. A third build with
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG WISP_DIAGNOSTICS"` also succeeds, so the gated code
  still compiles.
- Diagnostic entry points: `--dump-context` and `com.yichenlin.Wisp.show` are absent from the standard
  Debug dylib and the Release binary, and present in the flagged build. Xcode 26 keeps Debug code in
  `Wisp.debug.dylib`; checking the main executable alone gives a false negative.
- Egress inventory: three call sites (provider, Ollama probe, update check), all on the ephemeral
  configuration with redirects refused. No `URLSession.shared`, WKWebView, Network.framework or raw
  sockets remain. Wisp has zero `os_log`/`NSLog`/`print` call sites.
- Documents: docs/privacy-audit-e2e-20260907.md, docs/evidence/privacy-audit-e2e-20260907.json.
  JSON validates; `git diff --check` passes.

Outstanding:
- Preserving an existing explicit `checkForUpdates` value rests on `UserDefaults.register(defaults:)`
  semantics. This machine has no explicit value, so it was not exercised on real data.
- CLI argv exposure (Claude Code, AGY) is documented, not removed. Codex still uses the user's own
  CLI configuration.
- OS-level records, browser-observable activity, provider-side retention and gateway forwarding remain
  outside Wisp's control; the accepted full-display capture fallback is unchanged.
- Nothing was committed, published, or installed; `/Applications/Wisp.app` was not touched this round.

## Current extension: all-surface visibility audit — 2026-09-07

Goal: establish, per surface and per capture path, whether anyone recording, screenshotting, sharing or
remotely viewing this Mac can see Wisp — while keeping the user's own machine fully functional, including
their own Spotlight search over their own data.

Requirements (append-only):
11. Enumerate every visible surface Wisp creates and prove coverage per surface, not per known window.
12. Test capture paths beyond ScreenCaptureKit, including the legacy APIs remote-control tools use.
13. Find dead code and configuration that is not actually in effect.
14. Keep local usability intact: the user must still find their own data and use every feature.
    (Corrected mid-task: an earlier Spotlight-exclusion change was reverted for this reason.)

Decisions:
- Local data stays indexed by Spotlight on purpose; the threat model is what other people see on screen,
  not what the user can find on their own machine.
- The installed /Applications/Wisp.app was not started or stopped; it was running throughout and only
  observed read-only.
- Surfaces are enumerated from CGWindowList by owner pid, so a surface no protection path reaches cannot
  be missed by construction.

Validation (2026-09-07):
- Surfaces: assistant panel, island, settings window, popover, sheet, alert all carry sharingType=0 and
  show 0 marker pixels in the hidden group; the visible control shows 0.150-0.863, so the capture chain
  demonstrably sees them. popover and sheet are already 0 on their first frame, before the run loop turns.
- The menu window (layer 101) is absent from NSApp.windows — no code path sets it — yet shows 0 marker
  pixels on every path. Observed system behavior, not a guarantee.
- Menu bar icon: its app-side window still reports sharingType=1 after applyToAllWindows(), and it does
  not appear among the process's CGWindowList windows. It cannot be hidden by this mechanism. Pixel
  confirmation failed on this machine (icon placed off-screen at x=-4227; menu bar hidden by a
  full-screen foreground app).
- Capture paths: ScreenCaptureKit, CGWindowListCreateImage and CGDisplayCreateImage (both resolved via
  dlsym, since the current SDK marks them unavailable) all show 0 in the hidden group.
- Mission Control: the panel configuration measures 4 marker pixels (noise), the ordinary titled window
  configuration measures 2181. Controls: 238968/237006 visible with hiding off, 0/0 with hiding on and no
  Mission Control. Three candidate fixes failed (.transient 2181, floating level 2181, panel collection
  behavior 2145). So Wisp's Settings window is visible in Mission Control; panel and island are not.
- Dead code: clean build has zero compiler warnings. Removed ScrollDriver.requestTrust(),
  PromptBuilder.estimateTokens() and ConversationStore.remainingTurns(in:) — defined, never called.
- Full XCTest 20 passed, 0 failed, 0 skipped. Debug and Release builds exit 0. git diff --check passes.
- Documents: docs/screen-visibility-audit-20260907.md, docs/evidence/surface-visibility-20260907.json.

15. (Added after review) Make the menu bar icon optional, since it cannot carry the hiding request.
    Completed: AppSettings.showsMenuBarIcon (default true), MenuBarExtra(isInserted:), a gear
    SettingsLink in the panel header shown only while the icon is hidden, and a Settings toggle with
    text explaining both states. Debug and Release build, 20 tests pass. Runtime behavior NOT verified
    because the installed app was never started or stopped; the user was told to confirm after restart.
16. (Decided) Leave the Settings window as an ordinary titled window and document the Mission Control
    exposure instead of rebuilding it as a borderless panel.

17. (User-approved, executed) Test macOS built-in Screen Sharing over RFB. Partially completed: a
    self-written minimal RFB client (tools/screen-privacy/VNCFrameProbe.swift, password read from stdin)
    connected to 127.0.0.1:5900 with security type 2 and captured a full 3024x1964 frame. The frame is
    the login/lock screen, 99% non-black, average RGB (134,91,80), with 0 marker pixels — while the same
    moment's screencapture of the physical screen showed 239034/237006 marker pixels with hiding
    disabled. A VNC-password session is therefore isolated from the console session entirely.

Outstanding:
- The console-session half of remote sharing is still untested. The server offers security types
  [30, 33, 36, 31, 32, 2, 35]; taking over the live session needs Apple's private types, which require
  the account password. Not implemented, not requested. Verifying it needs a second device and a human
  looking at that device's screen.
- Third-party remote control (TeamViewer, AnyDesk, Sunlogin) untested.
- Space switching, Mission Control animation frames, multiple displays, system permission dialogs,
  capture cards and phone cameras remain out of scope.
- Open product decisions: whether to offer hiding the menu bar icon, and whether to rebuild the Settings
  window as a borderless non-activating panel to escape Mission Control.

## Current task: Live listening — 2026-09-08

Goal: add opt-in microphone/application audio transcription and explain recent speech through Wisp's existing provider.

Requirements (append-only):
24. Three modes: microphone, selected application's audio, both separately labeled.
25. Local live captions with timestamps and persistent text sessions; optional audio retention.
26. Explicit explain-recent action through the selected LLM without capturing a new screen.
27. Permission/error/stop states, bounded resources, lifecycle cleanup; no invisibility guarantee.
28. macOS 14 compatibility; device-only transcription or explicit unsupported-language error.
29. Build and meaningful regression checks; update usage/privacy docs and disclose untested hardware paths.

Decisions:
- Keep existing DS/native panel styling; no external visual redesign.
- AVAudioEngine microphone + ScreenCaptureKit selected application audio; no video retention in v1.
- Device-only SFSpeechRecognizer with a bounded serial queue of 1–4 second source batches supports the existing deployment target without assuming concurrent device recognition. This trades a few seconds of caption latency for compatibility.
- Raw audio is off by default. Explicit start is required; manually hiding the panel stops capture; switching between captions and chat keeps it running.
- Existing unfinished privacy scope above remains historical and outside this feature.

Validation (resumed 2026-09-09):
- Requirements 24–29 are implemented; hardware validation remains outstanding below.
- Fresh Debug build and full XCTest suite: 46 passed, 0 failures. Result bundle:
  `/private/tmp/wisp-listening-resume-20260909-r2.xcresult`; log:
  `/private/tmp/wisp-listening-resume-20260909-r2.log`.
- Initial sandboxed attempt failed on compiler/SwiftPM cache permissions; the approved
  retry with standard cache access succeeded. This was an environment failure, not a test failure.
- Prior Release build log `/private/tmp/wisp-listening-release.log` ends BUILD SUCCEEDED;
  prior final suite also passed 46 tests. Release was not rerun in this continuation.
- Reviewed capture cleanup, bounded serial recognition, transcript persistence, explicit
  explanation without new screen context, and data-reset callback invalidation.
- Inspected native idle-view renders at the panel width and 380 points:
  `/private/tmp/wisp-listening-ui.png` and `/private/tmp/wisp-listening-ui-narrow.png`.
  Normal panel layout is readable. Narrow English rendering truncates the audio-source
  label and application hint; the shared application label remains Chinese in English.
- `git diff --check` and localization JSON parsing pass.
- Usage and privacy documentation are present in docs/live-listening.md, both READMEs,
  PRIVACY.md and CHANGELOG.md.

Outstanding / delivery limits:
- Live microphone/application capture, actual permission prompts, language-resource
  availability, transcription accuracy and sustained two-source throughput have not
  been exercised. Synthetic tests do not establish those hardware-dependent behaviors.
- macOS 14 and Intel runtime compatibility are not tested; the build targets macOS 14.
- Narrow-layout truncation and the shared English application-label translation remain
  minor UI limitations; active-caption UI was not visually exercised.
- No model CLI was invoked, no personal audio was captured or sent, and no installed
  application was replaced, committed or pushed during this continuation.

## Follow-up: bounded storage and manual sharing — 2026-09-09

Requirements (append-only):
30. Audit audio buffers, transcript history, disk growth and conversation growth; fix unbounded listening storage.
31. Keep transcription local and quiet: no completion notifications, sounds, automatic clipboard writes or external sends.
32. Let the user choose transcript segments, copy them or stage an editable draft, and send only through the existing manual Enter/send action.
33. Preserve window privacy requests and accurately document OS indicators and recorder-specific limits.
34. Clarify whether hiding the panel should keep an explicitly started recording active; answer pending.

Decisions:
- Preserve the existing native DS/Raycast-inspired panel; add native selection controls without a redesign.
- Do not delete existing history automatically. Refuse new listening sessions at the storage budget.
- Existing draft text must survive staging; newly arriving captions must never append themselves to a staged draft.
- No real microphone capture, clipboard mutation or external message is needed for synthetic verification.

Follow-up implementation/evidence:
- Replaced immediate explanation submission with explicit segment selection, Copy selected,
  and Add to draft. Staging appends to existing input, requests input focus, snapshots text,
  skips new screen context on manual send, and never invokes a provider or clipboard itself.
  A draft-mode hint discloses that current conversation history still accompanies submission.
- Selection has a 12,000-character combined draft budget without silent truncation. New
  captions do not auto-select, auto-copy, auto-send or grow the draft. Selecting pauses
  automatic scrolling. No notification/sound/attention APIs were found in Wisp source.
- Listening archive admission now reserves 32 MiB (text only) or 544 MiB (audio) within
  2 GiB and at most 100 session directories. No old files are deleted. Unexpected nested
  folders/links fail closed. Per-source PCM is checked before write, with at most 128 parts.
- Transcript updates reject over 200,000 characters / 2,000,000 UTF-8 bytes / 7,200 segments
  before mutation, including late results. Unchanged transcripts are not checkpointed again.
- Recognition timeout/callback closures retain only batch IDs, allowing completed PCM to
  release immediately rather than waiting for the ten-second timer.
- Fresh Debug suite including final input-focus change: 52 passed, 0 failed (7.267 s).
  `/private/tmp/wisp-listening-manual-focus-20260909.xcresult` and matching `.log`.
  Added regressions cover selected-only payloads, no silent truncation, existing-draft
  preservation, snapshot stability, Unicode/segment limits, sparse-file disk admission,
  no old-record deletion, immediate PCM release, and staging without message/clipboard changes.
- Native idle renders at normal and 380-point widths inspected. Normal panel controls are
  readable; narrow configuration leaves a short scrollable caption region. Source-label
  truncation and the English application label were corrected. Active/live device UI is not tested.
- Read-only local metadata: Listening directory absent; conversations.json 27,141 bytes.
  No conversation content, real audio, credentials or Claude CLI state was read.
- Conversation counts default to 10 × 30 turns, but generic message/response bytes and some
  manual archive paths are not hard-capped. Corrected the old approximate-50-MB documentation
  so it is not described as a guarantee. No automatic transcript-to-chat history stream exists.
- Apple documentation confirms the legacy capture flag must not be relied on universally;
  macOS microphone/system-audio indicators remain visible. Existing panel privacy requests
  are preserved. No claim of new recorder-specific coverage is made.
- Requirement 34: optional clarification received no reply during implementation. Preserve
  hide-to-stop for now; switching listening/chat continues an explicitly started session.
  Changing hidden-panel behavior remains a user preference, not a prerequisite for these fixes.
- Docs: docs/live-listening.md, PRIVACY.md, both READMEs and CHANGELOG.md updated.
  JSON/English action-label checks and git diff --check pass.
- No installation, commit, push, external message or real audio capture performed.
- Final Release build (including input focus): exit 0, BUILD SUCCEEDED; log
  `/private/tmp/wisp-listening-manual-release-final-20260909.log`. Both arm64 and
  x86_64 compile steps succeeded; this is compilation, not Intel runtime validation.

## Follow-up: audio settings and focused cleanup — 2026-09-09
Requirements (append-only):
35. Audit settings and add missing audio preferences, permission checks and volume access.
36. Add a focused one-action cleanup for listening records, without clearing chats/API keys.
37. Match existing restrained native settings styling; move optional explanations to info controls.
38. Explain Apple on-device speech recognition and the limits of replacing system privacy indicators.
Decisions:
- Continue the existing Raycast-inspired native grouped forms and InfoButton pattern.
- Volume/device control opens macOS Sound settings; do not invent an ineffective recording slider.
- Cleanup is user-triggered with a destructive confirmation; no actual user records are deleted during testing.
- No silent automatic deletion policy is enabled. The existing total storage admission budget remains.

Settings follow-up evidence:
- Added Audio tab using existing grouped Form/SettingsSectionHeader/InfoButton styling.
  Source/language/audio retention persist via a Codable UserDefaults value; preferences
  remain locked while capture is active. Per-session application selection stays in the panel.
- Added microphone, Speech and screen/system-audio status/request/system-settings rows,
  an Apple on-device engine label, language support check, and macOS Sound entrypoint.
  No fake gain slider; actual device/volume controls remain owned by macOS.
- Data → Listening records → Clear confirms destruction and removes only Listening/.
  Capture must be stopped; late callbacks are invalidated first. Errors remain inline.
  Existing full reset remains separate. No automatic timed cleanup policy was enabled.
- Header uses a five-point dot on the waveform: red recording, orange starting/stopping;
  accessible text reports state. No system indicator override is implemented.
- Official Apple support https://support.apple.com/en-us/118449 confirms its supported
  external/full-screen exception still leaves privacy indicators on the main display.
  Source uses SFSpeechRecognizer, supportsOnDeviceRecognition and requiresOnDeviceRecognition;
  no Whisper weights/backend or macOS 26 SpeechAnalyzer backend is used.
- Full Debug suite: 55 passed, 0 failed (8.566 s),
  `/private/tmp/wisp-audio-settings-20260909.xcresult`; matching log confirms TEST SUCCEEDED.
- Additional full-height UI render: one test passed, zero failures;
  `/private/tmp/wisp-audio-settings-render-20260909.log`.
- Visually inspected `/private/tmp/wisp-audio-settings.png`,
  `/private/tmp/wisp-audio-settings-full.png`, `/private/tmp/wisp-data-settings.png`.
  Normal 620×520-point forms scroll for lower rows; full-height render verifies Sound row.
  Labels and controls fit without long always-visible explanations.
- Synthetic cleanup removed transcript/audio fixtures, preserved sibling chat bytes and a
  symlink target, was safe to repeat, and freed storage admission. No real user files deleted.
- Preference round-trip and invalid-locale/corrupt-value fallback tested in a temporary
  UserDefaults suite. Settings rendering left capture inactive; permission grants were not requested.
- English labels/JSON and git diff --check pass. Usage, privacy and changelog docs updated.
- Limitations: real permission dialog interactions, System Settings deep-link destinations,
  physical audio volume changes and live recorder compatibility remain untested. Existing
  model-provider settings were not exercised against real services/CLIs in this audit.
- Nothing installed, committed, pushed, or sent. No microphone capture or privacy-indicator
  system configuration changes were performed.
- Release build exits 0, BUILD SUCCEEDED:
  `/private/tmp/wisp-audio-settings-release-20260909.log` (arm64 and x86_64 compilation).

39. User correction: only capture other-party/video application playback; never open Wisp microphone capture. Implemented immutable application mode in ListeningModel, removed microphone authorization path and selectable source modes/permission request UI. Existing saved preferences cannot enable microphone. Retained backend is not exposed. Application loopback/echo is not speaker-filtered.

40. User supersedes requirement 39: restore all three source modes for debugging/testing, run checks, then install into Applications. Microphone remains opt-in; default is application audio. Installation explicitly authorized this turn.
- Requirement 40 verification: all 56 tests pass (8.600 s), /private/tmp/wisp-restored-audio-tests.log; signed Release BUILD SUCCEEDED, /private/tmp/wisp-restored-audio-release.log. Universal x86_64 + arm64; strict codesign verification passes, audio-input entitlement present, no debug entitlement. Settings render inspected and localization JSON/git diff --check pass.
- User-authorized install completed at /Applications/Wisp.app; executable comparison and strict signature check pass. Previous app backed up at /private/tmp/wisp-restored-install-z7u7wP/previous-Wisp.app. App launch requested successfully; no automatic recording or real microphone test performed. No commit or push.

41. User requests integrated single-line transcription above the existing AI chat; remove recording-page clutter, stop/shortcut draft or copy, manual Enter/send with screen context; fix broken resizing. Supersedes separate ListeningView destination and speech-only context bypass.
- Default stop behavior: stage recent unstaged speech after drain (optional async preference unanswered); no automatic provider submission. Control–Option–R toggles capture, Control–Option–D stages, both configurable. Application selection moved to Audio settings.
- Reproduced resize failure in native fixture: root hosting reset heights to 36 and minimum width to zero even with sizingOptions=[]. Fixed using an AppKit NSView container, with SwiftUI as its autoresizing child.


## Current extension: uncommitted health audit — 2026-09-09
42. Investigate intermittent menu-bar loss and prevent persistent accidental disappearance while preserving explicit hiding.
43. Review all uncommitted changes, especially speech capture, lifecycle, storage, draft/send and window interactions; fix confirmed defects.
44. Rerun meaningful tests and Debug/Release builds; distinguish synthetic coverage from live hardware verification. Do not commit, install, invoke real model CLIs or send captured content.

Decisions/evidence (in progress):
- MenuBarExtra writes insertion removal back into its binding (Apple documentation). Separate runtime insertion from the stored opt-out, allow one reinsertion per explicit setting change, and expose settings from every panel state.
- Initial isolated build failed dependency resolution because sandbox DNS/network access was denied; approved Xcode retry is running.
- Preserve earlier unresolved requirements and historical evidence above; this audit does not certify previous hardware/privacy claims.

Health audit evidence:
- Baseline 72 tests and fixed full suite 75 tests pass with zero failures; final result `/private/tmp/wisp-health-final.xcresult`.
- Universal unsigned Release build passes; architectures x86_64 + arm64. Native compact chat, narrow recording row and transcript page inspected; corrected transcript fixture background and targeted render test passes.
- Installer fixture exercises success, copy failure and both signature-failure stages; all four pass with old bytes preserved/restored. Reproduction: `python3 tools/test-install-local.py`.
- Detailed scope, fixes and unverified hardware/menu cases: docs/health-audit-20260909.md. Syntax, plist, localization JSON, source membership and diff whitespace checks pass.
45. User explicitly authorizes replacing /Applications/Wisp.app with the repaired version and reopening it. Signed build and installation now in progress; preserve prior app backup. This supersedes requirement 44's no-install constraint only.

Requirement 45 installation evidence:
- Signed Release build succeeded using the existing Apple Development identity; certificate-anchored designated requirement, not ad-hoc. Log: /private/tmp/wisp-health-signed-build.log.
- Gracefully quit prior installed PID 23082, installed the verified candidate and reopened /Applications/Wisp.app. New PID 28894 observed.
- Strict deep signature verification and executable byte comparison pass; installed binary contains x86_64 + arm64.
- Previous bundle: /var/folders/bj/_6886nzd0rd2f4vvw_2bdq7h0000gn/T/wisp-install-backup.6MmioI/previous-Wisp.app. Installation log: /private/tmp/wisp-health-install.log.
- Native AX confirms running Wisp and an Open Assistant control. Screenshot inspection failed with ScreenCaptureKit -3811, so physical menu-icon visibility/recovery is still not certified.
- Installer now fails closed when process enumeration itself fails. Four install fixtures pass after final script edits. No commit or push; live audio remains untested.

## Current follow-up: voice visibility and additional recognition model — 2026-09-09
46. Verify Settings can hide/show the voice bar and preserve working voice controls. Existing Audio → Enable voice input gates the row, prevents starting while disabled, stops capture on disable, and closes the transcript destination. Fresh Debug build and full suite: 76 tests passed, zero failures; /private/tmp/wisp-voice-settings-check-20260909-r2.xcresult. Real audio hardware was not exercised.
47. Integrate the user's referenced Hugging Face speech-recognition model. Awaiting exact model name or document/link; repository docs contain no Hugging Face model reference. Current engine is Apple on-device Speech. No model selected, downloaded, or integrated yet.
- Initial test attempt failed on sandbox compiler/package cache writes; approved retry succeeded. No installation, model CLI invocation, or external audio transmission performed.

48. User identified and authorized SenseVoice Small integration: add a persisted engine option, reuse ~/Documents/huggingface/models/k2-fsa/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17 without copying/downloading weights, preserve Apple Speech and the voice enable switch.
- Native dependency pinned to sherpa-onnx 1.13.7, matching NoType; official Package.swift supports macOS 10.15+, within Wisp's macOS 14 target. Use bounded batches and a separate serial inference queue. No automatic cloud fallback or model-file deletion.
- Acceptance: engine/language selection persists, missing files fail clearly, SenseVoice bypasses Speech authorization, synthetic regressions plus real bundled sample WAV decode, Debug/Release builds and settings render. Installation is not part of this request.

SenseVoice implementation evidence (2026-09-09):
- Requirements 47–48 resolved: model identified in the shared Documents/huggingface location and wired into a persisted Audio engine picker. Existing preference JSON migrates without losing source/locale/retention; default remains Apple Speech. SenseVoice language defaults to auto. Voice enable/disable behavior is preserved (requirement 46).
- Shared files are read only. No model installer, duplicate weights, model deletion or cloud fallback. Native CPU initialization and inference run on a serial background queue; scheduler cancellation ignores late results. PCM conversion preserves batch duration at 16 kHz mono; capture permissions remain source-specific while SenseVoice bypasses Speech authorization.
- Final Debug suite: 81 passed, zero failures, zero skips; /private/tmp/wisp-sensevoice-verified.xcresult and /private/tmp/wisp-sensevoice-verified.log. Real installed-model test decoded bundled English and Chinese WAVs in 1.191 seconds (including loading); this is an integration smoke test, not an accuracy benchmark. Earlier runs exposed overly specific sample assertions, corrected after examining output; Chinese wording varied.
- Native settings render /private/tmp/wisp-sensevoice-settings.png inspected with English translations: picker, automatic language option, shared-model file status, no Speech permission row in SenseVoice mode. No capture started.
- Documentation, privacy text, English/Chinese README, changelog, sherpa-onnx/ONNX Runtime licenses and third-party notices updated. Localization JSON and git diff --check pass.
- No installed app replacement, live microphone/application recording, model CLI invocation, transcript submission, commit or push. Sustained live audio accuracy, Intel hardware runtime and macOS 14 runtime remain unverified.
- Universal unsigned Release build succeeded: /private/tmp/wisp-sensevoice-release.log. `lipo -info` confirms x86_64 and arm64 in Build/Release/Wisp.app/Contents/MacOS/Wisp. This verifies compilation/linking for both architectures, not Intel runtime behavior.

49. User explicitly authorizes installing the SenseVoice-enabled build into /Applications. Build with the existing Apple Development identity, preserve the old bundle, reopen and verify the installed executable/signature. Signed build in progress; use the verified installer staging/rollback steps.
- Requirement 49 complete: signed Release build succeeded (/private/tmp/wisp-sensevoice-signed-build.log); installed and reopened /Applications/Wisp.app. PID 2381 observed. Strict deep signature verification and byte comparison with Build/Release/Wisp.app/Contents/MacOS/Wisp both pass outside the sandbox; installed binary is arm64 + x86_64.
- Previous app backup: /var/folders/bj/_6886nzd0rd2f4vvw_2bdq7h0000gn/T/wisp-install-backup.mZnTXV/previous-Wisp.app. Install log: /private/tmp/wisp-sensevoice-install.log. Sandbox-only verification initially lacked signing trust/process access; authorized verification succeeded. No recording started and no model selection changed.

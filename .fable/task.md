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

## Current task: CLI streaming — 2026-09-07

Goal: save the current code remotely, then make Codex and AGY deliver answer text incrementally.

Requirements (append-only):
18. Commit and push the pre-change work. Completed: 17999d2 on origin/main.
19. Switch Codex to app-server text deltas, retaining model/image input, private ephemeral
    read-only execution, cancellation, timeout and cleanup.
20. Verify AGY stream-json event shapes and implement incremental text without duplicate final output.
21. Run meaningful regressions and update user-facing protocol documentation.
22. (Added) Default Fast on where supported for Codex/Claude; check AGY support.
    Codex selects the model-advertised Fast service tier. Claude passes fastMode for supported
    Opus selections only; no model substitution. AGY removed /fast in 1.1.0 (official modes docs).
23. (Clarified) Fall back to original mode when Fast is unavailable. Codex retries a tier rejection
    once before text, Claude keeps native fallback, AGY uses normal mode; model/effort stay unchanged.

Decisions/evidence:
- Prior privacy tasks above retain unresolved scope; their historical evidence is not new validation.
- Codex 0.153.4 schema and official app-server docs checked. Synthetic live request: first text
  3.930 s, turn complete 5.129 s, ephemeral thread confirmed.
- AGY 1.1.27 synthetic live request: text deltas at 3.101/3.301/3.502 s, result at 3.502 s.
- No Claude CLI access, personal screenshots, installed-app replacement or new streaming-change push.
- Requirements 18–23 completed. Full Debug XCTest: 32 passed, 0 failed, 0 skipped;
  /private/tmp/wisp-cli-streaming-fast-tests-20260907. Release build exits 0.
- Codex live thread/start checks echoed priority and default tiers for the same Luna model.
- Details and limits: docs/cli-streaming.md; docs/evidence/cli-streaming-20260907.json.
- At initial delivery, the implementation remained local and uncommitted. Installed app unchanged; Claude live execution
  and end-to-end screenshot/UI testing were not performed. The pre-change baseline is pushed.
- Follow-up installation completed: /Applications/Wisp.app replaced, ad-hoc signature verified,
  executable matched the signed staging bundle, and the restarted process was observed (PID 8168).
  Backup: /private/tmp/wisp-install-PXmylM/previous/Wisp.app.
- User subsequently authorized committing and pushing the streaming/Fast implementation to main.

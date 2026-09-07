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

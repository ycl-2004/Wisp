# Uncommitted health audit — 2026-09-09

## Conclusion

The reviewed changes build and pass synthetic regression checks. Live speech and
physical menu-bar recovery are not yet fully validated. This is not a guarantee
that macOS always has space to display an icon or that every conferencing app works.

## Confirmed defects fixed

- MenuBarExtra used the saved visibility preference directly as its insertion
  binding. Apple writes false to that binding when an item is removed. Runtime
  insertion is now separate, with one recovery attempt per preference change and
  a panel fallback on repeated removal. Explicit hiding still works. The panel
  always exposes Settings; reopening Wisp from Finder already reveals the panel.
  Source: https://developer.apple.com/documentation/swiftui/menubarextra
- Opening the transcript from a collapsed panel now expands it and exits the
  conversation list, so the requested page is actually displayed.
- Copy transcript now copies the entire current transcript and remains enabled
  after staging and while an answer streams.
- Analysis checks conversation capacity before consuming pending segment IDs.
- Storage admission rejects the root directory itself when it is a symlink,
  including a dangling link, in addition to the existing child-entry checks.
- Privacy/usage docs distinguish ordinary Stop/Add to draft from the two explicit
  analysis actions. Those actions submit directly with screen context/history;
  they do not provide a second review pause.
- Installation stages and verifies the candidate before moving the existing app,
  preserves the previous bundle and restores it if activation/verification fails.

## Scope and evidence

Reviewed the uncommitted app lifecycle, menu, listening model/capture/scheduler/
transcript/storage, draft/send, panel/resize/header/transcript UI, settings,
permissions, entitlements, project source membership, localization and installer.

- Baseline: 72 tests, zero failures, `/private/tmp/wisp-health-baseline-r2.xcresult`.
- After fixes: 75 tests, zero failures, `/private/tmp/wisp-health-final.xcresult`.
  Log: `/private/tmp/wisp-health-final.log`.
- Debug test build and universal Release build succeed. Release log:
  `/private/tmp/wisp-health-release.log`; `lipo -archs` reports x86_64 and arm64.
- Native fixtures cover all voice-row states at 620/380 points, panel resize and
  drag routing, and raw transcripts. Inspected compact chat and narrow recording
  renders. Added a solid background to the transcript render fixture so its text
  can be inspected; that targeted render test also passes:
  `/private/tmp/wisp-health-render.xcresult`.
- `tools/test-install-local.py` executes the production install block against
  temporary fixtures. Success, copy failure, staged-signature failure and
  post-install-signature failure pass; failure paths preserve/restore old bytes.
  No actual signing tool or /Applications mutation occurs in that fixture.
- `bash -n`, plist validation, localization JSON parsing and `git diff --check`
  pass. Every Swift source has a project reference.
- Current saved menu visibility was read as `1` (enabled). That does not establish
  that the icon was physically visible or identify the user's intermittent event.
- No actual model CLI or provider request was invoked. Provider tests use pure
  parsers, intercepted HTTP and synthetic executable fixtures.

## Remaining verification and limits

- Microphone/application audio, permission prompts, available language resources,
  accuracy, two-source throughput, stop-time drain and long-meeting behavior need
  live testing. No personal audio was recorded during this audit.
- Menu recovery is state-tested and compiled, not physically exercised through
  Command-drag, menu-bar crowding, third-party managers, sleep, full-screen or
  multiple-display transitions. macOS controls available menu-bar space.
- macOS 14 and Intel were compile targets, not tested runtime environments.
- Speech is recognized in short serial batches, not speaker diarization. Labels
  identify sources, not people. A 12,000-character transfer budget can omit old
  batches; full text remains in local records. Corrections to already transferred
  segment IDs are not retransferred. These remain documented design limits.
- The full suite has an existing weak-variable compiler warning; Release reports
  skipped AppIntents metadata extraction because the app has no AppIntents dependency.
- The user subsequently authorized installing and reopening the signed build;
  installation evidence is recorded in `.fable/task.md`. No commit or push.

## Authorized installation

The signed repaired build is installed at `/Applications/Wisp.app` and was reopened
(PID 28894). Strict signature verification, executable byte comparison and universal
architecture checks pass. Prior app backup: `/var/folders/bj/_6886nzd0rd2f4vvw_2bdq7h0000gn/T/wisp-install-backup.6MmioI/previous-Wisp.app`.
The native accessibility tree exposes Wisp's Open Assistant control. Screenshot
inspection failed with ScreenCaptureKit error -3811; it does not establish whether
the physical menu icon is visible. Logs: `/private/tmp/wisp-health-signed-build.log`
and `/private/tmp/wisp-health-install.log`. No commit or push.

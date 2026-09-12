# Wisp non-audio acceptance plan — 2026-09-11

This is the repeatable acceptance record for the current working tree. It covers the
privacy cursor repair and all non-audio flows that can be exercised without sending a
real model request. It is evidence for this Mac and this build, not a universal
compatibility or security certification.

## Result at a glance

| Area | Result | Evidence |
| --- | --- | --- |
| Cursor artwork and native composer behavior | Pass | 6 focused cursor tests; composer insertion, selection, cursor update, Return and Escape in the 80-test suite |
| Conversation persistence and limits | Pass | Isolated create/stream/reload/select/delete, capacity, future-format and corrupt-history tests |
| Settings and chat surfaces | Pass | Seven settings tabs and empty/answer/streaming/error/history chat states rendered at 380/620 pt widths |
| Window interaction | Pass | 10 selected window/menu/header/resize tests; native cursor probe clicks, selects, scrolls, drags and resizes |
| Cursor lock in sampled video | Pass (bounded) | 16/15/14 SCK frames for off/on/restored; on-mode captured arrow stayed fixed while local arrow moved |
| Privacy capture matrix | Pass (sampled paths) | 115 synthetic capture groups, no marker leaks; windows remain enumerable |
| Browser page/capture lifecycle | Pass (synthetic) | 22 deterministic integrity checks plus Chromium 152 synthetic media/page script run |
| Release packaging | Pass | Universal2 (`x86_64 arm64`), strict ad-hoc signature, no debugger entitlement; final candidate installed to `/Applications/Wisp.app` after verification |
| Audio | Skipped by request | No audio capture, transcription or playback was run |

The raw machine-readable record is [evidence/non-audio-20260911.json](evidence/non-audio-20260911.json).

## What changed

- `LocalCursorController` now owns two click-through, nonactivating arrow-only windows:
  a private moving arrow (`sharingType = .none`) and a parked shared arrow
  (`sharingType = .readOnly`). The parked arrow is pre-drawn before being occluded by
  Wisp, so layer-backed SwiftUI content does not suppress its first frame.
- AppKit/SwiftUI cursor requests are normalized to `NSCursor.arrow` process-locally,
  including text field editors and selectable response content. No mouse warping,
  event rewriting or global event tap was added.
- Privacy lifecycle restores the system cursor on menu tracking, leave, deactivation,
  hide, disable, screen changes and termination. A generation token prevents a delayed
  screenshot from reopening a panel dismissed during presentation.
- `AppSettings` and `ConversationStore` accept isolated defaults/files for tests; no
  user preferences or conversation files are used by the acceptance fixtures.

## Reproduce

From the repository root:

```sh
bash tools/verify-non-audio.sh unit     # 80 main XCTest + 10 selected window tests, installer and static checks
bash tools/verify-non-audio.sh native   # synthetic AppKit windows, SCK video and privacy matrix; controls the mouse briefly
bash tools/verify-non-audio.sh release  # Universal2 Release/signature check; leaves a candidate in /private/tmp
```

Each invocation writes an evidence directory under `/private/tmp/wisp-nonaudio.*` and
does not install, publish, call a model, or invoke the Claude CLI. Native mode requires
an idle desktop and existing screen-recording permission.

After the release check, the user-authorized installation used the verified candidate and
moved the previous `/Applications/Wisp.app` to
`/private/tmp/wisp-install-backup.GpWsfK/Wisp.app` before placing the new bundle. The
installed bundle reports version `0.4.0 (6)`, contains `x86_64 arm64`, and passes
`codesign --verify --deep --strict`.

## Cursor acceptance details

The probe uses a cyan positive-control window and a magenta private-content marker. It
captures a continuous ScreenCaptureKit stream with `showsCursor = true` and no excluded
windows. The validator requires a positive background and pointer in every frame,
zero private markers, a fixed arrow boundary in `on`, moving boundaries in `off` and
`restored`, native interactions, and restoration after leaving. Seven intentionally
broken reports (blank, moving, missing, leak, reshaped, hidden-local and no-resize) are
rejected by the validator's self-test.

The tested result was 16 `off`, 15 `on`, and 14 `restored` frames. The static screenshot
control is deliberately reported separately: off/restored contained pointer pixels,
while the on-mode static screenshot did not. Therefore this change promises a stationary
arrow for the sampled continuous video path only. A receiver that transmits pointer
metadata, uses a different capture path, or ignores `NSWindow.sharingType` may behave
differently.

## Scope limits and follow-up gates

The following were intentionally not claimed as passes: real model/API requests (the
credit-use question was unanswered), real `getDisplayMedia` desktop selection,
Zoom/Meet/Teams/Feishu/OBS/Screen Studio/remote-desktop receivers, multiple displays,
Spaces/Mission Control, sleep/wake, permission prompts, and long-duration production
CPU/RSS/energy measurements. The native probe's CPU percentage is a short synthetic
fixture signal (about 2.3–4.1%), not a production performance budget. Run those gates
on a clean test account and with the actual receiver before relying on privacy behavior.

# Wisp local cursor experiment — 2026-09-11

## Goal
Test whether hiding the system cursor and drawing it inside Wisp preserves mouse interaction while omitting the pointer from compatible capture paths.

## Acceptance criteria / append-only requirements
1. Optional local cursor mode, default off, with existing screen privacy required.
2. Keep native mouse clicks, selection, scrolling, dragging and resizing; restore the cursor on exit, deactivation, menus, disable and termination.
3. Validate in independent capture processes with cursor inclusion ON and positive controls; report unsupported/untested sharing paths honestly.
4. Build and install the tested version at /Applications/Wisp.app for user evaluation.
5. General sharing/recording compatibility is the target, not a guarantee inferred from a single recorder.
6. Keep the visible Wisp cursor as an arrow everywhere while preserving resize and drag gestures.

## Decisions
- User approved testing the local cursor proposal; no whole-window duplicate or mouse position warping in production.
- AppKit/SwiftUI, macOS 14 minimum. Use NSCursor hide/unhide with balanced ownership and a click-through local drawing view.
- Resize hit-testing remains unchanged; all cursor artwork now resolves to `NSCursor.arrow`.
- Experiments use synthetic content, local capture only, no meeting transmission or model calls.
- Commit and push the verified experiment together with its tests, probe, and user-facing documentation.

## Evidence
- `xcodebuild test` passed 127 tests in `/private/tmp/wisp-local-cursor-tests/Logs/Test/Test-Wisp-2026.09.11_07-21-20--0700.xcresult`, including the arrow-only resize regression check.
- `/private/tmp/wisp-local-cursor-capture-2/result.json` has off/on/restored groups with cursor-including ScreenCaptureKit, system screenshot and system video captures. Dark cursor pixels were 49/0/49 in the SCK shots and 234/0/234 in system screenshots; native interaction recorded clicks=1, text=`cursor test`, selectionLength=11, scrollY=140.
- Release build, signing, and replacement completed with `tools/install-local.sh`; `/Applications/Wisp.app` now contains the arrow-only revision at version 0.3.0 build 5.
- Browser `getDisplayMedia` probe was prepared and opened, but the OS screen-picker was not counted as completed because no user selection was made.

## Delivery / outstanding items
Requirements 1–6 are implemented and locally verified. Third-party sharing tools remain unverified; user-facing docs and changelog describe the mode as experimental and off by default.

Outstanding: verify the browser picker with the user's explicit screen selection; test Zoom, Meet, Teams, Feishu, OBS, Screen Studio and remote desktop; decide whether to keep the experiment after those results. No universal capture guarantee is claimed.

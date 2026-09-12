# Wisp privacy cursor and click feedback repair — 2026-09-12

## Goal
Repair reported cursor-lock gaps and put pointer artwork and click feedback under the privacy cursor lock switch.

## Acceptance criteria / append-only requirements
1. Diagnose and repair the reported privacy cursor lock failure using current code and observable tests.
2. Cover Wisp app surfaces and keep clicking, typing, selecting, scrolling, dragging and resizing usable.
3. Consolidate related cursor behavior under the existing privacy cursor lock switch, restoring normal behavior when off.
4. Added by user: remove both Wisp button press effects and recording/shared click circles when operating Wisp.
5. Added by user: support all kinds of recording/sharing tools if possible.
6. Added after installation: a local moving pointer must never coexist with a stale, duplicate or overlapping pointer. Inspect transparent surfaces, window movement, transitions and cleanup rather than only a stationary shared-pointer assertion.
7. Preserve a single parked pointer in recordings only if compatible with requirement 6. The optional preference was unanswered; proceeded with the stated assumption that no duplicate pointer takes priority and compatible recordings may omit it.
8. Added during duplicate-cursor repair: test clicks, typing, buttons and selections in recordings; no interaction effects or operation records should appear while using Wisp. Full suppression of independent third-party event recording cannot be provided by Wisp. Local feedback clarified by requirement 9.
9. User clarified: hide interaction feedback only in shared/recorded output; preserve local editing/selection indicators.
10. Build the latest source and replace `/Applications/Wisp.app`, as explicitly requested earlier in this task; preserve a rollback copy.
11. User explicitly authorized committing and pushing the delivered source, tests and documentation to the repository.

## Decisions / authority
- Preserve all pre-existing worktree edits. The prior completed task is archived verbatim in history.md.
- No Claude CLI, model calls, release publication or system recorder preference changes. Requirement 11 now explicitly authorizes source commit and push.
- Build a reviewable local app. The user explicitly authorized replacing `/Applications/Wisp.app` in this task; keep a rollback copy.
- Synthetic local native capture/input probes are within the requested verification scope; restore pointer and foreground app afterward.
- Preserve native input. Do not suppress/replay global input to interfere with other apps' recordings.

## Evidence / status
- Inspected production cursor controller, privacy lifecycle, settings, native resize/button styles, tests and previous capture evidence.
- Baseline native probe PASS_SAMPLED_VIDEO: 16/15/15 frames off/on/restored. It did not enable recorder click effects. Evidence: /private/tmp/wisp-cursor-repair-20260912/baseline-native/result.json.
- Confirmed code gaps: arrow swizzle unconditional; non-key/nonactive floating surfaces rejected; menus always release lock; title bars excluded; refresh scheduled only after dispatch.
- Click-enabled recorder probe reproduces independent click overlays despite a parked arrow: 42/41/41 frames, validator correctly fails the on group. This part of requirement 4 cannot be implemented globally by Wisp; recorder-side controls are documented for requirement 5.
- Arrow/resize cursor normalization and custom/plain button feedback now follow the lock switch. Settings title bars and protected in-process menu/popover targets are included; native drag ownership lasts to mouse-up.
- Real held-button pixel validation passed 6/6 (Press/Icon/Plain, on/off), each action exactly once. Images inspected; evidence is synthetic content only.
- Native background test rejected the intermediate non-key workaround: isReplacing=true but 9 captured pointer bounds. Corrected production waits for activation, restores during background hover, and activates only on explicit clicks after remembering the external capture target.
- Final activation probe: 15 frames each off/inactive/on/restored; on group exactly one pointer bound, background uses normal cursor, no private markers captured.
- Final XCTest: 24/24 pass, result /private/tmp/wisp-cursor-repair-20260912/final-regression.xcresult. Structural diff/Swift probe/Python/shell/JSON checks pass.
- Evidence and limitations: docs/cursor-lock-repair-20260912.md and docs/evidence/cursor-lock-20260912.json.
- Final Universal2 Release passed strict codesign verification and has no debugger entitlement. The current source was rebuilt and installed by `tools/install-local.sh --keep-backup`. Installed bundle is Universal2, version `0.4.0` build `6`, and its designated requirement is anchored to the Apple Development certificate. Rollback copy: `/var/folders/bj/_6886nzd0rd2f4vvw_2bdq7h0000gn/T/wisp-install-backup.WyA2Bb/previous-Wisp.app`. No Claude CLI, model use, commit, push, publication or recorder setting changes.
- Duplicate repair: removed the public parked window, hide system cursor before showing the one private arrow, detach/remove before restoration; ordinary host child ordering handles immediate dismissal. Miniaturization and owner switching are covered.
- Continuous native recordings exposed a second root cause: AppKit menu tracking calls an unmatched NSCursor.unhide and consumes Wisp's hide. Added ownership accounting so matched native pairs remain intact while menu tracking cannot release the private hide. Menu child ordering stays under AppKit control.
- First continuous probe stalled because debug-built per-pixel component detection could not keep up with 30 fps. Sampled the process, stopped only task-owned fixture processes, and rebuilt the probe with `swiftc -O`.
- Native menu/drag failures were investigated with temporary event traces. The runner's Down/Return sequence selected an item without reliably finishing menu tracking. The probe now makes an actual menu-item click; subsequent native drag/resize and 6/6 button controls pass. Temporary event traces were removed from the source.
- Intermediate transparent native validation passed 380 continuous frames and six captured interaction stages, with 8/8 validator counterexamples rejected. Final regression and installation remain pending.
- Final native verification passed 480 continuous frames, 15/15/15 settled frames, 6/6 native interaction stages, 6/6 button controls and 11/11 rejected validator counterexamples. Post-menu restoration shows one real system pointer and no private overlay. Background activation passed 401 continuous frames. Source and reports: `/private/tmp/wisp-single-cursor.7AFr2v/verified-native-r2`, `final-activation`.
- New recorder click-effect counterexample: 27 of 40 locked frames contain recorder-added pixels when `showMouseClicks=true`; validator fails as required. Other native interactions remain hidden. Evidence: `recorder-click-control/result.json`.
- Final XCTest: 25/25 pass (13 cursor + 9 non-audio + 3 related window tests), `/private/tmp/wisp-single-cursor.7AFr2v/final-regression.xcresult`. Signed install pending.
- Installed the final certificate-signed Universal2 Release in `/Applications/Wisp.app` and launched it. Version 0.4.0 (6); strict signature passes; binary matches Build/Release; no debugger entitlement. Backup: `/var/folders/bj/_6886nzd0rd2f4vvw_2bdq7h0000gn/T/wisp-install-backup.Xxa34U/previous-Wisp.app`. Actual settings UI opened and both window hiding and privacy cursor lock observed enabled. Evidence: `docs/evidence/single-cursor-20260912.json` and `docs/single-cursor-20260912.md`.
- Commit preparation: verified production source hashes still match the passing tests and installed build. Updated the native verification wrapper to use the same `swiftc -O` setting as the tested probe, avoiding the previously diagnosed pixel-analysis backlog. Commit/push now authorized by requirement 11; no new release or app binary upload requested.

## Delivery status
Delivered and installed the duplicate-cursor repair, including the menu-unhide regression uncovered by continuous capture. Requirements 1/2/3/6/7/9/10 are delivered within the tested scope. Requirements 4/5/8 remain limited by recorder-owned click overlays, independent activity records, and unverified third-party capture paths; this is documented with an actual failing recorder-side positive control. No guarantee of universal capture prevention. Requirement 11 authorizes source commit/push; the resulting commit and remote verification are reported in the delivery message. No Claude CLI, model use, release publication, permission grants or recorder preference changes.

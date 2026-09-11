# Screen privacy research and hardening — 2026-09-10

## Goal
Prioritize preventing capture of Wisp over availability. Research macOS boundaries and comparable apps, exercise independent local capture paths, implement evidence-backed improvements, and report unresolved guarantees honestly.

## Acceptance criteria / append-only requirements
1. Find methods to validate without a second physical device.
2. Research native APIs and comparable apps using primary sources.
3. Treat hiding as the primary requirement; explicitly distinguish local visibility, software captures, system surfaces, and physical capture.
4. Extend tests to expose false-positive privacy results, including live filter changes.
5. Make justified production changes with regression validation.
6. Deliver a cited research report, test evidence, and next steps; do not claim universal invisibility.

## Decisions
- User asked to prefer hiding even at the cost of functionality. Optional clarification on stopping local display received no answer; preserve current operation and document strict-mode behavior as a pending product choice.
- No new commit/push/install requested in this research turn. Prior installed version is 8828c76.
- No model CLI or model requests required.
- Existing prior reports contain a known settings/Mission Control exposure and a VNC login-session false control; new evidence must not erase these limitations.

## Evidence
- Final evidence and scope are recorded below.

## Decision log / evidence updates
- Apple online documentation explicitly disclaims NSWindowSharingNone as a prevention guarantee; SDK comments are older. Native AVSampleBufferDisplayLayer.preventsCapture is available on macOS and was tested independently of window sharingType.
- A transient Space policy was initially considered for Mission Control. Reading the complete older evidence showed it had already failed pixel validation. Reverted that trial; no Mission Control fix claimed or shipped.
- Production change: attach ScreenPrivacyWindow to InfoButton, context notes, response timing and notices sheet; correct misleading AppSettings comment. No capture detectors, private production APIs or window-type changes.
- Research report: docs/screen-privacy-research-20260910.md; raw non-image metrics and summary in docs/evidence/screen-privacy-20260910/.
- 114 A/B sample groups passed across 4 SCK filter configurations, live updates, direct window screenshots and 5 native movie samples per mode. Windows still enumerated.
- Validator rejects blank controls and missing frames as INCONCLUSIVE, and an injected 0.000001 marker fraction as LEAK.
- Surface A/B covers SCK and two legacy capture APIs. Hidden target fractions zero with positive counterparts; an alert lacked a positive marker and remains inconclusive. Popover and sheet attachment sharingType was 0 hidden / 1 visible.
- Nine production lifecycle checks pass; final XCTest 69/69 pass in /private/tmp/wisp-privacy-popover-final.xcresult.
- No model CLI invoked, no network screen transmission, no commit, push or install. Installed version remains 8828c76.

## Delivery / outstanding items
Research, reproducible tests, bounded hardening and documentation requirements 1–6 delivered. The universal-invisibility objective is not achieved and cannot be represented as a supported macOS guarantee.
Outstanding: strict-mode product choice; real Wisp lifecycle/Space animations and multi-display testing; Mission Control leak remediation with positive pixel evidence; other meeting receivers and current-session remote desktop; protected video interaction prototype. These are not marked as passed by the matrix.

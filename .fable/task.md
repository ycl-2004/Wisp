# Response modes — 2026-09-09

## Goal and acceptance criteria
Make Wisp responses faster with explicit accuracy tradeoffs, selectable Quick/Deep models, editable shortcuts and supported acceleration for API/CLI. Keep legacy Standard data decodable for migration while exposing only Quick and Deep to customers, with Quick as the default. Preserve existing voice behavior. Compile and test the actual integration; do not claim model accuracy without a benchmark.

## Append-only requirements
50. Add Standard/Quick/Deep response behavior, explicit context/accuracy guardrails and observable latency measurements.
51. Allow mode and model selection while answering; provide configurable mode shortcuts.
52. Persist a manually chosen model for each Quick/Deep mode for each connection, including API and CLI.
53. Prefer supported Fast/priority in every mode; fall back conservatively when acceleration is rejected. Keep the same model and free-model status.
54. Validate regressions and document usage, limitations and a representative accuracy/latency comparison procedure.
55. Replace the installed `/Applications/Wisp.app` with the newest signed build and preserve a rollback copy.
56. Keep response accuracy/model choices associated with the exact API endpoint or CLI connection, and restore the matching choices when switching connections.
57. Present these choices with compact dropdowns and clearly show the active software/connection and effective model.
58. Keep explanatory copy behind an information button so the customer-facing settings page stays compact.
59. Remove existing rollback copies and make successful local replacements clean temporary backups while retaining the stable team signature workflow.
60. Remove Standard from the customer-facing mode picker, use Quick as the default, and present only two compact rows pairing each mode with its shortcut and model.

## Decisions
- Existing context/history and prior outstanding hardware/privacy limitations are preserved verbatim in history.md. Previous installed voice work is commit 36c39c3 on origin/feat/add_voice_detect.
- A send snapshots configuration before preparation; changes during a response affect the next send without restarting the active request.
- Mode shortcuts are unassigned until the user records them; no takeover of existing keys.
- Quick skips new page-text collection, retains existing evidence, and uses low supported reasoning. Deep waits for configured capture and requests high supported reasoning. Legacy Standard remains only for decoding and migration, and maps to Quick in current settings.
- Fast is independent of effort. Retry once without priority only on an explicit tier rejection before any answer; do not retry auth/rate/transport/unrelated failures.
- A connection profile is keyed by provider kind plus normalized API scheme/host/port/path, or CLI provider plus normalized executable path. Cosmetic URL case, whitespace and trailing slashes share a profile; different endpoints and CLIs do not.
- No Claude CLI invoked and no live model API calls. Installation was explicitly requested after the build; no commit or push was requested in this follow-up.

## Evidence
- Initial full Debug run: 88 tests, zero failures; /private/tmp/wisp-response-modes-tests.xcresult.
- Final full Debug suite: 91 tests, zero failures; /private/tmp/wisp-response-modes-layout.xcresult and /private/tmp/wisp-response-modes-layout.log. Includes real streaming-transport fixture for single priority fallback, per-mode effort/fast routing, persisted overrides, immutable selections and UI rendering.
- Inspected opaque settings render /private/tmp/wisp-response-settings.png and 380-point collapsed panel /private/tmp/wisp-response-narrow.png. Raised collapsed minimum/default to 180 points so the voice and mode rows fit; prior saved shorter frames are clamped.
- Localization JSON and git diff --check pass. Universal unsigned Release build succeeded: /private/tmp/wisp-response-modes-release.log. lipo confirms arm64 + x86_64 in Build/Release/Wisp.app/Contents/MacOS/Wisp.
- Physical shortcut keypresses, account-specific Fast eligibility and live model accuracy/latency remain unverified. No commit or push.
- Manual benchmark procedure: docs/model-speed.md. Actual provider accuracy and latency remain unmeasured.
- Signed installation: `/Applications/Wisp.app` replaced and reopened as PID 22495. The installed executable matches `Build/Release/Wisp.app` byte-for-byte; `codesign --verify --deep --strict` passes; designated requirement is certificate-anchored; installed binary contains `x86_64 arm64`. Previous app was retained by `tools/install-local.sh` in its generated rollback backup.
- Connection profile regression: normalized endpoint/path identity and separate API/CLI profile behavior pass in `/private/tmp/wisp-connection-profiles-tests.xcresult`; full suite remains 91 tests with zero failures. Settings render now shows the active connection and its effective model, with menu pickers for mode and per-mode model choices.
- Final UI/profile verification: `/private/tmp/wisp-connection-profiles-final.xcresult` passes 91 tests with zero failures. The rendered settings surface shows dropdowns for response mode and Quick/Deep model choices, concise customer-facing guidance, and the active connection label. The installed updated app is running from `/Applications/Wisp.app` as PID 43333; binary/signature checks pass. Latest rollback copy: `/var/folders/bj/_6886nzd0rd2f4vvw_2bdq7h0000gn/T/wisp-install-backup.gtZa4O/previous-Wisp.app`.
- Information-button cleanup: long mode/Fast guidance is now behind the existing reusable `ⓘ` popover; only the mode, connection, shortcuts and model controls remain visible.
- Backup policy: five previously identified `wisp-install-backup.*` directories were deleted after confirming each contained only an old Wisp bundle. `tools/install-local.sh` now keeps a rollback copy only until the move/signature checks pass, deletes it on success, and supports opt-in `--keep-backup`.
- Final signed replacement after the UI cleanup succeeded. `/Applications/Wisp.app` is running from the newly installed build; its SHA-256 matches `Build/Release/Wisp.app/Contents/MacOS/Wisp` (`e6e02ccdf2495c87881b72346360e9d835ff3b3017a5f6acbf75b7dbbc4c8457`), the certificate-anchored signature and `x86_64 arm64` slices verify, and no `wisp-install-backup.*` directory remains.
- Quick/Deep-only verification: `/private/tmp/wisp-two-modes-tests.xcresult` passes 92 tests with zero failures. The installed Model settings accessibility tree shows Quick as the selected default, Deep as the only other mode, one shortcut/model pair per mode, current connection/model text, and explanatory copy available through `ⓘ` buttons rather than always-visible paragraphs.
- Final test rerun with the project's non-signing test configuration also passes 92 tests with zero failures: `/private/tmp/wisp-two-modes-tests-final3.xcresult` and `/private/tmp/wisp-two-modes-tests-final3.log`. A signed Release build remains the installed customer artifact.

## Delivery status
Requirements 50–60 implemented and locally verified (11/11). Live provider benchmarking and physical shortcut delivery remain explicit limitations, not established accuracy or speed claims. Changes are uncommitted.

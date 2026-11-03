# Wisp Deep Audit — Findings, Fixes, and Risk Register

- **Date:** 2026-11-02
- **Scope:** Local clone `~/workspace/wisp-review`, branch `fix/audit-2026-11-02`, base commit `1e86359` (v0.4.0). The GitHub remote was not touched: no pushes, no API writes, no settings changes.
- **Method:** Manual code reading of all 76 Swift files' relevant paths (LLM providers, capture, listening/speech, stores, settings, app lifecycle), `project.yml`, CI workflow, `.gitignore`, README/README.zh-TW/PRIVACY/CHANGELOG, and programmatic checks of the string catalog (`Localizable.xcstrings`, 767 keys) against source call sites.
- **Verification limits:** There is **no Swift toolchain on this machine**, so nothing here was compiled or test-run. Plist files were validated with Python `plistlib`; `.strings` files with a strict format/key check; the checksum fix was proven with a filesystem simulation; every commit's diff was reviewed before committing. Fixes were kept to changes that are trustworthy without compilation (resources, docs, comments, one encoder format flag, one byte-exact string-literal change). Everything requiring real code changes is a proposal with the verification it needs.
- **Companion doc:** `CODE-REVIEW-2026-11-02.md` (first-pass review; its findings were re-verified — two did not survive verification, see Appendix A).

**Totals: 26 issues — 5 fixed, 1 partially fixed (comment corrected, behavior change proposed), 19 proposed, 1 wontfix within this pass's constraints.**

Severity scale: High = affects most users or creates real security/data risk · Medium = affects a significant subset or a realistic failure mode · Low = narrow, unlikely, or polish-level, but real.

---

## (a) Issue list

### Fixed on this branch

**1. System permission dialogs fell back to Simplified Chinese for English and Traditional Chinese users**
- Severity: Medium · Category: UX/adoption
- Evidence: `Wisp/App/Info.plist` carries `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSAppleEventsUsageDescription` in zh-Hans only; no `*.lproj` directory existed anywhere in the repo (`git ls-files`); `CFBundleDevelopmentRegion` is `zh-Hans`, so any user whose system language isn't zh-Hans sees Chinese text in the macOS permission prompts — the very first thing a new user reads.
- Status: **Fixed in `980cdc2`** — added `Wisp/Resources/en.lproj/InfoPlist.strings` and `Wisp/Resources/zh-Hant.lproj/InfoPlist.strings` with translations of the three strings. XcodeGen picks up `.lproj` folders under the target's sources on regeneration, and CI already runs `xcodegen generate` (`.github/workflows/ci.yml`), so no project-file edit was needed. Keys validated against `Info.plist`. Remaining verification: one Mac build to confirm the variant group lands in the app bundle.

**2. Published `.sha256` could not be verified outside the repo root**
- Severity: Medium · Category: release/distribution
- Evidence: `README.md:627` documented `shasum -a 256 dist/Wisp-macOS-universal.zip > dist/Wisp-macOS-universal.zip.sha256`, which records the filename as `dist/Wisp-macOS-universal.zip` inside the checksum file. Uploaded to a GitHub release next to the zip, `shasum -a 256 -c` then fails with "No such file or directory" for every downloader who isn't in the repo root — silently undermining the only integrity check users have (the hash value itself is correct). Same pair at `README.zh-TW.md:429` and `:458`; no release script exists (`tools/` has only install/test/verify helpers), so the README commands *are* the release process.
- Status: **Fixed in `f5bee43`** — both READMEs now generate and verify from inside `dist/` so the recorded name is the bare zip name. Proven by simulation: generated a checksum the new way, copied zip+sha256 to a fresh folder, `shasum -a 256 -c` → `OK`.

**3. Conversation store pretty-prints a file it fully rewrites on every change**
- Severity: Low · Category: data loss / performance
- Evidence: `Wisp/Store/ConversationStore.swift:42` — `outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`, while `persist()` (same file, lines 107–124) re-encodes and rewrites the *entire* history file on every append/context-update/delete. Pretty-printing inflates every one of those writes and the on-disk size of a plaintext file that can grow to the conversation/turn caps.
- Status: **Fixed in `facccbf`** — dropped `.prettyPrinted`, kept `.sortedKeys` (deterministic output). Decoding is whitespace-insensitive, so existing files read identically.

**4. Code comments claimed the update check sends "no identifying information" — it sends the app version**
- Severity: Low · Category: security/privacy (documentation accuracy)
- Evidence: `Wisp/Support/AppLifecycle.swift:103` ("不带任何标识信息") and `Wisp/Support/AppSettings.swift:467` ("只发一个不带标识的请求") vs `AppLifecycle.swift:142`, which sets `User-Agent: Wisp/<currentVersion>`. `PRIVACY.md:126–129` already discloses this correctly (IP + `Wisp/<version>` UA), so the code comments were the inaccurate party.
- Status: **Fixed in `0763e96`** — comments corrected to match PRIVACY.md. Comment-only change. (The historical `CHANGELOG.md:418` line "It sends nothing about you or your usage" was deliberately left alone: changelogs are history, not current documentation.)

**5. "Delete all data" does not reset settings, and its doc comment claimed it did**
- Severity: Low · Category: security/privacy
- Evidence: `Wisp/Support/AppSettings.swift:548–558` — the comment on `wipeLocalData()` promised clearing "对话 JSON、调试文件、UserDefaults", but the implementation removes the support directory and only 5 UserDefaults keys (`lastActiveConversationID`, `panelFrame`, `islandOrigin`, `islandAnchor`, `cloudModels`). Provider configs, custom endpoints, CLI paths, and excluded-app lists all survive the wipe (the caller at `SettingsView.swift:1636–1645` additionally clears conversations and the Keychain; the Settings alert text itself is accurate). A user wiping before handing over a machine would reasonably expect endpoints and provider setup to be gone.
- Status: **Partially fixed in `99cda6e`** — comment rewritten to state exactly what is removed and that settings survive. **Proposed (behavior):** decide the product intent — if "删除全部数据" should mean factory reset, iterate over all `AppSettings.K` keys and remove them; needs a Mac-side check that no first-launch default depends on a removed key being present-but-empty vs absent.
- Status (round 5): **Behavior implemented in `c6dc30f`** (YC approved) — `K.all` enumerates all 41 keys and `wipeLocalData()` removes every one; the absent-vs-empty question was settled reader-by-reader (registered defaults live in the volatile registration domain; every unregistered reader nil-coalesces to its fresh-install fallback; the one presence-based reader, `adoptLegacyCloudConfig`, is unreachable after the wipe's Keychain-first caller order). The Settings button/section/alert copy was updated to match exactly (「删除全部数据与设置」), catalog +3 keys → 784. Harness-verified: `AppSettingsWipeTests` 4/4. Full record: `AUDIT-ROUND5.md`.

**6. Invisible raw U+00A0 / U+200B bytes inside injected-JavaScript regexes**
- Severity: Low · Category: maintainability
- Evidence: `Wisp/Capture/PageTextScript.swift:19` and `:74` — the character class in `wClean`'s regex contained literal NBSP (bytes `C2 A0`) and zero-width space (`E2 80 8B`) characters: invisible in editors and diffs, impossible to review, and one careless edit away from silently changing page-text normalization for every captured page.
- Status: **Fixed in `e5ef22e`** — byte-precise replacement with `\u00A0` / `\u200B` escapes, which mean exactly the same characters in a JS regex literal; neighbouring regexes in the same script already rely on backslash escapes surviving the Swift raw-string + AppleScript pipeline. Verified post-change that no invisible characters remain in the file. Remaining verification: existing BrowserTextExtractor tests on a Mac.

### Proposed (not safe to land without a Mac build / product decision)

**7. No notarization + ad-hoc signing: every update resets users' system permissions**
- Severity: **High** · Category: UX/adoption, release/distribution
- Evidence: `README.md:619` — the documented release build uses `CODE_SIGN_IDENTITY=-` (ad-hoc); `README.md:495` — "each build has a different code [identity]"; `README.md:513` — "ad-hoc signed and not Apple-notarized, so Gatekeeper may…". Because an ad-hoc build's designated requirement is a cdhash, macOS treats each update as a different app: users must re-grant Screen Recording, Microphone, Speech Recognition, Automation, and re-approve Keychain access after *every* update. `tools/install-local.sh`'s header documents this mechanism in detail (it exists precisely to dodge it for local installs).
- Proposal: Sign releases with a Developer ID certificate and notarize (requires the paid Apple Developer Program and a decision by YC on identity/cost). Interim mitigation already partly present: keep telling users in release notes that permissions need re-granting. Verification: notarized build → `spctl` assessment on a clean Mac + update-over-previous-version permission retention test.

**8. No first-run onboarding: the app can't answer anything until the user finds Settings and configures a provider + API key**
- Severity: Medium-High · Category: UX/adoption
- Evidence: No onboarding/first-run code exists anywhere in `Wisp/` (the only "Welcome to Wisp" string is a DEBUG renderer fixture, `Wisp/UI/IslandRenderer.swift:120`). A new user gets a panel, asks a question, and hits an unconfigured-provider state; the only path forward is discovering Settings → provider section → pasting an API key (or installing a CLI). For a project whose funnel is GitHub stars → downloads (see risk register: 39 total downloads vs ~169 stars), first-run friction is the most likely drop-off point.
- Proposal: Minimal first-run sheet when no provider is configured: pick cloud (paste key) / Ollama / CLI, with a "test connection" using the existing `validate(config:)` path. Verification: UX pass + fresh-profile manual test on a Mac.

**9. No Traditional Chinese UI localization, despite a Traditional Chinese README and audience**
- Severity: Medium · Category: UX/adoption
- Evidence: Programmatic check of `Wisp/Resources/Localizable.xcstrings`: the only languages present across all 767 keys are `en` and `zh-Hans`. `Info.plist` `CFBundleLocalizations` = `[zh-Hans, en]`. Yet `README.zh-TW.md` exists (HEAD commit `1e86359` "docs: add Traditional Chinese README") and the project's audience is Traditional-Chinese-first. Traditional users must choose between Simplified UI and English. (The new zh-Hant `InfoPlist.strings` in fix 1 covers permission prompts only.)
- Proposal: Either commission/produce a zh-Hant string pass (the catalog is well-maintained, so this is a translation task, not engineering), or consciously document zh-Hans-only UI. Verification: catalog language audit + locale-forced run (`-AppleLanguages '(zh-Hant)'`).
- Status (round 2): **DRAFT implemented in `377f6cc`** — all 767 keys gained machine-converted (OpenCC s2twp) zh-Hant values marked `needs_review`, `CFBundleLocalizations` extended. Validation was mechanical and run here (JSON re-parse, key-set/order identity, 0 format-specifier mismatches, en/zh-Hans byte-identical). This is a review starting point, NOT finished localization: it needs native review before release. See AUDIT-ROUND2.md #9. Follow-on gap found in round 3: the in-app language picker has no zh-Hant case (new finding #31).

**10. Cloud streaming: unbounded error-body accumulation and unbounded SSE lines**
- Severity: Medium · Category: security/privacy (robustness against a hostile or broken endpoint)
- Evidence: `Wisp/LLM/OpenAICompatibleProvider.swift:135–136` — on any non-2xx response, `var data = Data(); for try await byte in bytes { data.append(byte) }` accumulates the *entire* error body with no cap before `mapError` ever looks at it; `SSEParser.errorMessage` caps only the displayed message (400 chars). Line 144's `bytes.lines` likewise buffers a single SSE line without bound. The only backstop is the 300 s resource timeout (`:26`). Endpoints are user-configurable (custom base URLs are a headline feature), so a malicious/buggy endpoint can grow memory for up to 5 minutes per attempt — and the priority-rejection path retries.
- Proposal: Cap error-body accumulation (e.g. stop after 64 KiB — far beyond any real error JSON) and cap per-line length in the SSE loop, treating overflow as a network error. Needs Mac build + a local stub-server test. Note the redirect side of this provider is *correct* and needs no change: `PrivateAPIRedirectPolicy` refuses all redirects precisely so `Authorization` can't leak to another host.
- Status (round 2): **Fixed in `2281ce2`** — `CappedDataBuffer` (64 KiB, keeps head, records truncation) for error bodies; new `SSELineSplitter` (1 MiB/line) replaces `bytes.lines` in the streaming loop, overflow → network error. Tests (`WispTests/StreamGuardTests.swift`, 13) **ran green in the Linux harness**, including the provider loop end-to-end via a URLProtocol test; macOS CI-pending. See AUDIT-ROUND2.md #10.

**11. CLI providers: uncapped stderr accumulation**
- Severity: Low-Medium · Category: maintainability / robustness
- Evidence: `Wisp/LLM/ClaudeCodeCLIProvider.swift:398–411` — `DrainBuffer.append` grows a `Data` with no limit for the life of the run (up to the 300 s watchdog). `condense()` truncates only when *displaying*. A CLI stuck in a stderr-spewing loop (auth prompts, stack traces) can balloon memory; the same accumulation pattern should be audited in the Agy/Codex read loops when fixing.
- Proposal: Cap `DrainBuffer` (keep the last N KB — errors are read from the tail by `condense` anyway). Verification: unit test with a fake handle, Mac build.
- Status (round 2): **Fixed in `9aac158`** — the three identical private DrainBuffer copies (Claude/Agy/Codex) were deduplicated into one shared capped type in `ChatProvider.swift` (keeps last 256 KiB, trims on UTF-8 scalar boundaries). Tests (`WispTests/DrainBufferTests.swift`, 6) **ran green in the Linux harness**; macOS CI-pending. See AUDIT-ROUND2.md #11.

**12. CLI read loops block on `availableData` inside `Task.detached` — they occupy Swift cooperative-pool threads**
- Severity: Low-Medium · Category: maintainability / performance
- Evidence: `ClaudeCodeCLIProvider.swift:72` (`Task.detached` + blocking reads at `:108`, `:132`), `AgyCLIProvider.swift:116`/`:211`/`:235`, `CodexCLIProvider.swift:104`/`:137`. The authors know cancellation can't reach these loops (comments at `ClaudeCodeCLIProvider.swift:351`, `CodexCLIProvider.swift:31`) and correctly compensate by killing the process. The residual risk is structural: blocking reads pin cooperative-pool threads for up to 240–300 s per call; with several providers/probes active, unrelated async work can starve.
- Proposal: Move the blocking read loops onto a dedicated serial `DispatchQueue` (or a small pthread wrapper) so the cooperative pool only ever awaits. Behavior-preserving but threading-sensitive — Mac build + the existing CLI provider tests + a cancellation latency check required.

**13. Inconsistent CLI wall-clock timeouts: 300 s / 300 s / 240 s**
- Severity: Low · Category: maintainability
- Evidence: `ClaudeCodeCLIProvider.swift:14` = 300, `AgyCLIProvider.swift:12` = 300, `CodexCLIProvider.swift:9` = 240. Each is a separate literal with its own timeout error message; nothing documents why Codex gets 20% less. Users hitting a slow-but-working Codex get a timeout error a minute earlier than Claude users for no stated reason.
- Proposal: One shared constant (or an explicit per-provider rationale comment). Verification: trivial once decided; Mac build.
- Status (round 2): **Fixed in `72cac25`** — shared `CLIWallClock.timeout = 300` in `ChatProvider.swift`, all three providers alias it; per-provider error-message shapes preserved. Pin tests **ran green in the Linux harness**; macOS CI-pending. See AUDIT-ROUND2.md #13.

**14. Cloud requests identify the app as "Wisp/0.1" — a version that never shipped**
- Severity: Low · Category: security/privacy (accuracy of what's sent to third parties)
- Evidence: `Wisp/LLM/OpenAICompatibleProvider.swift:67` — `request.setValue("Wisp/0.1", forHTTPHeaderField: "User-Agent")`, hardcoded, while the app is at 0.4.0 (`project.yml` MARKETING_VERSION). Every API provider sees a stale UA; some gateways rate-limit or flag unknown/stale agents. The update checker does this correctly (`AppLifecycle.swift:142` derives it from the bundle version).
- Proposal: Derive from `CFBundleShortVersionString` the same way `UpdateChecker` does. One-line change, but it's a code change — Mac build to verify, per this pass's rules it was not landed blind.
- Status (round 2): **Fixed in `9465b06`** — `UpdateChecker.userAgent` derives from `currentVersion`; used by both the update check and the cloud provider. Derivation-wiring tests ran green in the Linux harness (against mirrored accessors — the real accessor lives in an AppKit file); macOS CI-pending. See AUDIT-ROUND2.md #14.

**15. Conversation persistence re-encodes and rewrites the whole history file on the main actor, per mutation**
- Severity: Medium · Category: data loss / performance
- Evidence: `Wisp/Store/ConversationStore.swift:4` (`@MainActor final class`), `:107–124` (`persist()` encodes the entire `ConversationFile` and atomically replaces the file), called synchronously from `append`, `updateContext`, `removeMessage`, `delete`, `createNew` (streaming updates deliberately skip per-token persists — good). As history approaches the configured caps, each turn end pays a full-file JSON encode of every conversation — including all captured page text — on the main actor: UI hitch risk plus write amplification on the user's SSD. Fix 3 shrinks the constant factor; the architecture is the issue.
- Proposal: Debounce/coalesce persists (e.g. 500 ms), and/or encode off-main with the snapshot passed by value; longer term, per-conversation files. Needs Mac profiling with a max-size fixture file (the test target already builds isolated stores — `ConversationStore(fileURL:settings:)` injection exists).

**16. Conversations and listening records are plaintext at rest (documented trade-off, worth an explicit decision)**
- Severity: Medium · Category: security/privacy
- Evidence: `ConversationStore` writes readable JSON containing full captured page text, selections, and Q&A history; `ListeningTranscript.save` writes `session.json` + `transcript.txt` (and optional audio) per session. Mitigations are real: the directory is created and re-pinned to `0700` (`AppSettings.swift:540–547`, whose comment honestly notes this "does not isolate same-user processes"), keys are *not* in these files (Keychain only — verified), and PRIVACY.md discloses local storage. The residual exposure is device theft/backup compromise, where FileVault is the only barrier, and the debug dump path (`ContextCapture.dumpForDebug`, opt-in, default off) writes the last screenshot + full page text to `debug/last-context.json` / `last-screenshot.jpg` in the same directory.
- Proposal: No code change demanded; make the trade-off a conscious, documented one in the risk register (below). If YC wants stronger posture later: optional passcode-locked encryption of `conversations.json` via CryptoKit + Keychain key is the sketched route. Verification: threat-model decision, not a build.

**17. Local speech models are user-supplied files parsed by native code, with no integrity story**
- Severity: Low · Category: security/privacy
- Evidence: By design Wisp never downloads models: users copy sherpa-onnx model folders into `~/Documents/huggingface/models/` themselves (`README.md:77`; `SettingsView.swift:1432` "Wisp 不会下载、复制或删除模型"). Wisp validates structure before use — `LocalSpeechModel` requires regular non-empty readable files and an intact ONNX container (`ONNXModelInfo` protobuf walk catches truncation/corruption) — but nothing verifies *provenance*: no checksums in docs, no pinned source. A model folder from a random re-upload is parsed by sherpa-onnx/onnxruntime native code.
- Proposal: Documentation-level: in `docs/live-listening.md`, name the canonical upstream sources for SenseVoice/Qwen3-ASR models and suggest verifying publisher checksums where offered. No code change. (In-app download with pinned hashes would be a *feature* decision for YC, not a fix.)

**18. CI runs only on macos-15, but the app supports macOS 14.0**
- Severity: Medium · Category: release/distribution
- Evidence: `.github/workflows/ci.yml:9` — the single job (tests + dual-arch Release build + signature checks) runs on `macos-15` only. `project.yml:5` sets deploymentTarget macOS 14.0 and `Info.plist:28–29` sets `LSMinimumSystemVersion` 14.0 — consistent with each other (verified, no drift), but no automated job ever builds or tests *for* 14.0, so an accidental macOS-15-only API use ships silently until a 14.0 user crashes. `SWIFT_STRICT_CONCURRENCY: minimal` in `project.yml` likewise means concurrency errors are warnings the CI doesn't gate on.
- Proposal: Add a `macos-14` runner job (build at minimum, tests ideally). Verification: CI run on the branch once pushed (requires YC's go-ahead — out of scope here).
- Status (round 2): **Implemented in `3d5af10`** — `test-and-release-check-macos-14` job mirrors the macos-15 job step-for-step. YAML-validated locally; first real run is CI-pending (branch unpushed). See AUDIT-ROUND2.md #18.

**19. "Universal binary" is shipped and Rosetta-verified, but never run on a real Intel Mac**
- Severity: Low · Category: release/distribution
- Evidence: `README.md` (~:640, Release validation notes): "Rosetta can run the x86_64 slice on Apple Silicon, but Intel hardware testing still needs to be performed separately." CI's `lipo -info` check proves the slice *exists*, not that it *runs* (e.g. sherpa-onnx/onnxruntime x86_64 behavior is untested). Downloads are small enough that the affected population may be tiny — but the claim "macOS-universal" is currently unverified on the hardware it names.
- Proposal: One manual smoke test on any Intel Mac per release, or soften the wording to "Universal binary (Intel slice untested)". Verification: manual.

**20. The app is ~101 MB (≈97 MB main binary) — heavy for a menu-bar utility**
- Severity: Medium · Category: UX/adoption, release/distribution
- Evidence: Measured on the published v0.4.0 artifact (first-pass artifact inspection). Likely composition: statically linked sherpa-onnx + onnxruntime (`Package.resolved`: `onnxruntime-libs 1.28.1`, `sherpa-onnx 1.13.7`) — but the breakdown was *not* measured; that requires Mac-side `size`/`bloaty`. Combined with no notarization (#7) and manual checksum verification (#2), download size is one more slice of install friction.
- Proposal: On a Mac, profile the binary (link map / `size -m`), check for dead-stripping and symbol stripping opportunities, and evaluate dynamic onnxruntime or an on-demand local-speech component. Verification: before/after link maps + full test suite.

**21. SettingsView.swift is a 1,974-line single file**
- Severity: Low-Medium · Category: maintainability
- Evidence: `wc -l`: `Wisp/UI/SettingsView.swift` 1974, `Wisp/UI/AssistantModel.swift` 641, `Wisp/Support/AppSettings.swift` 560, `Wisp/UI/ChatView.swift` 519. Every settings change — providers, audio, data, privacy — lands in one file, so review diffs are noisy and merge conflicts likely for any second contributor. The code inside is well-organized (marked sections, small subviews); this is a scale warning, not a quality complaint.
- Proposal: Split SettingsView by existing section boundaries into per-section files when next touched substantially. Pure refactor — needs Mac build + UI smoke pass.

**22. Inconsistent dependency pinning: SherpaOnnx is exact-pinned, KeyboardShortcuts is a version range**
- Severity: Low · Category: maintainability (supply chain)
- Evidence: `project.yml:11–16` — SherpaOnnx `exactVersion: 1.13.7` vs KeyboardShortcuts `from: 2.2.1`. Mitigation already in place: `Package.resolved` is committed (`Wisp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, currently resolving KeyboardShortcuts 2.4.0), and CI regenerates from it, so builds are reproducible *today*. The range only bites on an explicit resolve/update — at which point a global-hotkey library changing behavior is exactly what you don't want unreviewed.
- Proposal: Pin KeyboardShortcuts exactly, or document the policy ("native/runtime deps exact, UI utilities ranged"). One-line `project.yml` change + regeneration; classified as proposal because its effect (resolution behavior) can't be exercised without XcodeGen resolution on a Mac.
- Status (round 2): **Implemented in `3c30b64`** — `exactVersion: 2.4.0` (matching Package.resolved). Project not regenerated (needs XcodeGen; CI does it). CI-pending. See AUDIT-ROUND2.md #22.

**23. The author's personal team ID and manual signing identity are baked into the shared project file**
- Severity: Low · Category: maintainability
- Evidence: `project.yml:23–25` — `DEVELOPMENT_TEAM: BQYHJCCRMP`, `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "Apple Development"`. Anyone generating the project inherits YC's team; CI works around it by overriding signing settings on the command line (`.github/workflows/ci.yml`), and `tools/install-local.sh` re-derives the identity from the keychain. Not a secret (team IDs are public), but it's contributor friction baked into the canonical project definition.
- Proposal: Move team/identity into an untracked `xcconfig` or environment override with the committed default being ad-hoc (`-`), matching the release flow. Verification: fresh-clone `xcodegen generate` + build on a Mac without YC's certificates.

**24. Internal agent work-notes (`.fable/`, 722 lines) are tracked in the public repository**
- Severity: Low · Category: maintainability / hygiene
- Evidence: `git ls-files` includes `.fable/task.md` and `.fable/history.md` (672 lines) — AI-agent task specs, decision logs, and local evidence paths (e.g. `/private/tmp/wisp-cursor-repair-20260912/...`) from development sessions. No credentials or user data found in them (checked), so this is disclosure-of-process, not a leak: they reveal internal workflows and local paths, and they grow the public repo with material most users can't use.
- Proposal: YC's call — if intentional (radical transparency), leave and maybe say so; otherwise `git rm --cached` + add `.fable/` to `.gitignore`. Not changed here because intent is unknowable from code, and removing tracked files is a history-visible act that should be the owner's.
- Status (round 5): **Done in `d355763`** (YC approved) — `git rm -r --cached .fable` + `.fable/` added to `.gitignore`. Working-tree files verified byte-identical on disk (md5 before/after); only tracking stopped. History untouched.

**25. Force-unwrap on `strdup` in the speech-model C string pool**
- Severity: Low · Category: maintainability / robustness
- Evidence: `Wisp/Listening/LocalSpeechModel.swift:78` — `let pointer = strdup(string)!` in `CStringPool`. `strdup` only fails on allocation failure, so real-world crash risk is minimal — but it's a force-unwrap on a raw allocation inside the local-speech path, where a graceful model-load failure (the surrounding code has a proper error vocabulary) would be strictly better.
- Proposal: Return an optional / throw from the pool's append and let model loading fail with the existing `ListeningFailure` path. Small Swift change — Mac build + LocalSpeech tests.
- Status (round 2): **Fixed in `36555f6`** — pool records `allocationFailed` and serves a static empty string instead of trapping; `LocalSpeechRecognition.create()` checks the flag and throws the existing load-failure `ListeningFailure`. Tests written (`WispTests/CStringPoolTests.swift`, 6 — happy path only; the failure branch cannot be triggered without fault injection and is inspection-verified, stated plainly). CI-pending only — the file is outside the Linux harness closure (sherpa-onnx-bound). See AUDIT-ROUND2.md #25.

**26. GitHub repository has no topics (discoverability)**
- Severity: Low · Category: release/distribution
- Evidence: Repo metadata check in the first-pass review (topics empty; the repo is otherwise well-described with bilingual READMEs).
- Status: **Wontfix in this pass** — changing topics requires a GitHub API/settings write, and this pass's constraints put the remote off-limits. One-line follow-up for YC in the web UI (e.g. `macos`, `swift`, `ai-assistant`, `menu-bar`, `openai`, `ollama`, `speech-recognition`).

---

## (a2) Round 4 — adversarial multi-lane round (2026-11-02, later)

Four parallel lanes (security attack / concurrency & error paths / extreme inputs / test engineering) re-audited the whole surface, including everything rounds 1–3 settled. **No High-severity finding and no real injection, SSRF, or key-leak path was found** — lane 1's "attacked, held" list (Appendix B of `AUDIT-ROUND4.md`) is as much a result as the findings. New issues #33–#53; #52/#53 are proposals only. Full lane record, verdicts, and the Git Integration Guide: **`AUDIT-ROUND4.md`**.

Round-4 totals: **21 new issues — 17 fixed (some as combined commits), 2 proposals, plus #10 completed and #30 implemented along the way.** Branch state: 37 commits over base; final harness tally **194 tests, 192 passed, 2 known failures** (#32 characterization + SwiftPM bundle-ID artifact).

**33. Same-second corrupt-backup collision silently defeated the corruption recovery**
- Severity: Medium · Category: data loss
- Evidence: backup names had one-second granularity (`ConversationStore.swift` `moveCorruptFileAside`); a second recovery within the same second collided, `moveItem` failed, and `load()` proceeded with no backup and no `loadIssue` — the corrupt file stayed in place to be overwritten by the next persist.
- Status: **Fixed in `abc5d96`** — collision-aware retry with `-<attempt>` suffixes; genuine failure sets the new `LoadIssue.backupFailed` and blocks persistence. Linux-verified (lane 4's collision test rewritten from documenting to asserting).

**34. Newer-version protection bypassed by version *type*, not value**
- Severity: Medium · Category: data loss
- Evidence: `ConversationFileVersionProbe { version: Int? }` decoded with `try?` — a file with `"version": "2"` or `2.5` failed the probe entirely, `load()` skipped the guard, and the tolerant full decode substituted v1, later overwriting the file in v1 format. Negative versions likewise loaded and were rewritten as 1.
- Status: **Fixed in `0c7cb14`** — the probe now distinguishes absent vs present-but-undecodable; undecodable or `< 1` blocks with the new `LoadIssue.unreadableVersion`. Note: this deliberately changed the tolerant-decode contract for the `version` field only (lane 4's silent-fallback matrix updated). Linux-verified.

**35. Conversation store: existing-but-unreadable file, and every persist failure, were silent**
- Severity: Medium · Category: data loss
- Evidence: `load()` used `try? Data(contentsOf:)` and conflated "missing" with "exists but unreadable" (e.g. the path occupied by a directory), after which every persist failed into a store that looked fresh; `persist()` swallowed encode, directory-protection, and total write failures — a full disk meant a whole session's history vanished without a word.
- Status: **Fixed in `74b792f`** — unreadable-but-present blocks with `LoadIssue.unreadable`; persist failures set the published `saveIssue` (cleared by the next successful write), rendered in ChatView with the load-issue banner pattern. Catalog strings added. Linux-verified (banner is CI-pending).

**36. A CLI descendant holding the pipes defeats EOF: unbounded hang, unkillable read** — the round's most severe finding
- Severity: Medium-High · Category: robustness / resource leak
- Evidence: all three providers blocked on `availableData` and `CLICommand.run` awaited `readDataToEndOfFile`; process death was the only EOF source. A child that forks a pipe-holding descendant (daemonized helper, hung package manager) leaves the main process exited — the watchdog's `stop(onlyIfRunning:)` no-ops, cancel cannot interrupt the blocked read, and the detached task, pipes, and screenshot temp dir leak for the app's life; `CLICommand` hangs make Settings' connection test spin forever. Demonstrated pre-fix on Linux: a call whose child exits instantly returned only after the grandchild's full 30 s.
- Status: **Fixed in `86651a9`** — shared `PipePoll` (poll() in 250 ms slices) in all three provider loops (process gone + pipe drained ⇒ flush framer as EOF); `CLICommand` reads on threads into a `PipeSnapshotBox` and returns the snapshot after death + 2 s drain; a process surviving the kill sequence reports status −1 instead of blocking in `waitUntilExit`. Linux-verified incl. a live fork-hold reproduction; platform caveats (corelibs `isRunning` latch) recorded in the commit. Provider-loop integration on macOS is CI-pending.

**37. Claude RunBox: adopt→run gap could launch an unmanaged process**
- Severity: Medium · Category: concurrency
- Evidence: `ClaudeCodeCLIProvider` registered the process and called `run()` as separate steps outside the lock; a cancel/watchdog landing between them settled the box and dropped the handle, after which `run()` launched claude with no owner. Codex/AGY already launch inside the lock.
- Status: **Fixed in `147e199`** — Claude's RunBox gained the same `start()` (register + launch under one lock). CI-pending (private, Process-bound; mirrors a pattern verified twice in-repo).

**38. The three small-body reads were uncapped (completes #10)**
- Severity: Medium-Low · Category: robustness
- Evidence: `validate()` (OpenAICompatibleProvider), `OllamaSupport.probe()`, and `UpdateChecker.check()` still used `data(for:)` — a broken/hostile endpoint decided how much memory Wisp buffered.
- Status: **Fixed in `ee02135`** (with #46) — all three go through `cappedData`/`accumulate` over `CappedDataBuffer`, throwing `URLError.dataLengthExceedsMaximum` past 256 KiB (validate/probe) / 1 MiB (release JSON). Cap mechanics Linux-verified.

**39. Debug dump gate was a single defaults bool away from a screenshot oracle**
- Severity: Medium · Category: security/privacy
- Evidence: the dump writes `debug/last-context.json` + `debug/last-screenshot.jpg` at fixed paths, gated only on `debugDumpEnabled` in UserDefaults of a non-sandboxed app: any same-user process could `defaults write` it on and read screenshots — borrowing Wisp's Screen Recording grant, which the other process does not hold.
- Status: **Fixed in `5ebd5c1`** — the setter now also creates an arm file inside the 0700 support directory; the getter requires both. Honest scope (recorded in code): stops key-flipping scripts and commodity malware, not a source-aware same-user forger. Side effect: dumps enabled by older builds stay off until re-toggled. Linux-verified.

**40. Capture-state race: stale capture results overwrote newer ones wholesale**
- Severity: Medium · Category: concurrency / correctness
- Evidence: `AssistantModel.captureText()` copied `packet`, awaited seconds of scroll capture, then assigned unconditionally; refresh (`captureContext`) interleaving in the window could resurrect an older screenshot while `lastSentPacketID`/`lastURL` described yet another packet.
- Status: **Fixed in `64f6fbb`** (with #41/#42) — a `captureGeneration` bumped by every capture intent; both phases verify after each await and discard stale results wholesale. CI-pending (AppKit).

**41. Zombie capture: a cancelled capture still landed and poisoned the next send**
- Severity: Medium · Category: concurrency / correctness
- Evidence: `stopStreaming()` cancelled the preparation task and bumped `responseGeneration`, but capture's `runOffMain` continuation has no cancellation path — the zombie `captureShot` still assigned `packet`, set `isCapturing`, and cleared `contextIsStale`, so a stop + app switch + immediate resend could skip capture and answer from the cancelled shot.
- Status: **Fixed in `64f6fbb`** — stopStreaming and panelDidHide bump the capture generation and reset `isCapturing`; zombie landings are discarded entire. CI-pending (AppKit).

**42. A late follow-header could strip a Deep answer's just-read page text**
- Severity: Medium-Low · Category: concurrency / correctness
- Evidence: `applyHeader` checked only `Task.isCancelled` (at schedule time); a header landing between `captureText` and `performSend` for a different page nil'd `packet.pageText`/`pendingText`.
- Status: **Fixed in `64f6fbb`** — `applyHeader` refuses to land while capturing, preparing, or streaming; the 1 s follow timer re-offers it. CI-pending (AppKit).

**43. Keychain results discarded at every user-facing call site**
- Severity: Medium · Category: data loss (credential) / error paths
- Evidence: `_ = KeychainStore.save/delete` in SettingsView; `deleteAll()` returned nothing. A failed save was invisible and the connection test masked it by injecting the in-field key; a failed wipe could claim success while a key survived; legacy-key migration deleted the original even when the copy-write had failed (the one outright data-loss path).
- Status: **Fixed in `b74b743`** — `deleteAll()` aggregates to Bool; persistKey/runTest stop at a failed save and say so; the delete button and the wipe report failures honestly; migration deletes the original only after a copy is confirmed. Catalog strings added. CI-pending (Keychain/SwiftUI).

**44. Numeric settings had floors but no ceilings**
- Severity: Low · Category: robustness
- Evidence: `pageTextLimit` (free-form number field in Settings) had `max(2_000, …)` and no ceiling — raising it defeated the app's only page-text cut point (PromptBuilder has no budget; CLI paths stay protected by `CLIPrompt.fit`). Same pattern for `maxConversations`/`maxUserTurns`.
- Status: **Fixed in `18948a3`** — getter-side ceilings (500k / 50 / 200) following the existing opacity-clamp pattern, which also covers values written outside the UI. Linux-verified.

**45. Eviction was not streaming-aware**
- Severity: Low · Category: data loss (narrow)
- Evidence: `evictionCandidate`/`createNewEvictingOldest` never checked streaming state. Masked in practice because each chunk bumps `updatedAt` — but a *stalled* stream's conversation becomes the eviction victim and its answer vanishes mid-generation.
- Status: **Fixed in `c0dd4cc`** — the store tracks the streaming conversation (set by non-final `updateStreaming`, cleared by the final persistNow update / removeMessage / delete / deleteAll) and eviction skips it; the UI's "delete this one?" prompt inherits the fix. Linux-verified.

**46. Cloud provider leaked a URLSession per question (deepens #30)**
- Severity: Low · Category: performance / resource leak
- Evidence: a provider (and its `URLSession`) was created per send, never invalidated — delegates and connection pools grew with question count.
- Status: **Fixed in `ee02135`** (with #38) — default path uses one process-wide shared session with the identical ephemeral config + redirect policy; the configuration-injecting initializer remains per-instance for the URLProtocol test doubles. Also implements #30.

**47. runAppleScript read pipe buffers after a discarded wait timeout**
- Severity: Low · Category: concurrency
- Evidence: `BrowserTextExtractor.runAppleScript` discarded `group.wait(timeout:)`'s result, then read captured `outData`/`errData` unsynchronized — a pipe held open past process exit made the read race the reader threads and could return torn bytes as success.
- Status: **Fixed in `5c470b2`** — lock-synchronized `PipeResultBox`; a post-exit wait timeout is a failure, never a read. Sink Linux-verified; osascript path CI-pending.

**48. QuickCommandStore: corrupt blob silently reseeded, then overwritten**
- Severity: Low · Category: data loss (narrow)
- Evidence: init decoded with `try?` and fell back to seeded defaults — indistinguishable from first run; the user's commands looked "reset", and the first later edit overwrote the stored blob for good.
- Status: **Fixed in `993e939`** — failed decode sets published `loadFailed`, suppresses saving, shows an explicit notice in the settings pane; only an explicit Restore Defaults clears it. Tests WispTests-only, CI-pending (KeyboardShortcuts dependency keeps this store out of the Linux harness).

**49. Duplicate conversation/message IDs were never deduplicated on load**
- Severity: Low · Category: correctness
- Evidence: every lookup is first-match (append/update/streaming) except `delete` (removeAll): a hand-edited/merged file with duplicate IDs produced a copy that could be seen and deleted but never appended to, and a delete that silently took both.
- Status: **Fixed in `2fdcdcd`** — first-wins dedupe at both levels in `load()`; lane 4's documenting test now asserts. Linux-verified.

**50. Ollama probe reported wrong-shape JSON as "running, zero models"**
- Severity: Low · Category: correctness / error paths
- Evidence: probe parsed with optional casts ending in `?? []` — any valid JSON of the wrong shape (proxy error page, native `/api/tags` payload) yielded `.running(models: [])`; malformed JSON surfaced a raw Foundation error string.
- Status: **Fixed in `51abc3f`** — pure `models(from:)` returns nil for unrecognised shapes (empty `data` array still legitimately means zero models); probe maps nil to `.failed` with a readable message. Catalog string added. Linux-verified.

**51. One invalid UTF-8 byte silently erased a whole streamed line**
- Severity: Low · Category: correctness
- Evidence: `SSELineSplitter` decoded each line with `String(data:encoding:) ?? ""` — a single corrupt byte dropped the entire delta, and the answer was persisted with a hole in it. (Split-multibyte across chunks was already handled correctly.)
- Status: **Fixed in `cafe2e4`, scoped in `ce5a0ce`** — splitter decodes lossily (U+FFFD), matching the capped buffers' precedent; lane 4's documenting fuzz test updated to the new contract. The same commit's extension to `SSEParser.errorMessage` was **reverted** in `ce5a0ce`: an existing test pins the opposite, deliberate contract there (truncated error bodies fall back to a readable message instead of mojibake). Linux-verified.

**52. PROPOSAL — no cumulative cap on a streamed response**
- Severity: Low · Category: robustness / product decision
- Evidence: streaming has per-line caps (#10) but no total: a never-ending stream runs until the 300 s resource timeout, accumulating answer text and provider charges throughout.
- Status: **Proposal only** — a total-bytes or total-duration cap is a product decision (legitimate long Deep answers exist), not taken unilaterally.

**53. PROPOSAL — no startup sweep of orphaned CLI temp dirs**
- Severity: Low · Category: hygiene
- Evidence: CLI screenshot workspaces (`Wisp-claude-*` etc.) are removed on the happy path; a force-quit leaks them until the OS cleans the temp directory (contents include screenshots of the user's screen).
- Status: **Proposal only** — sweep `Wisp-*` temp dirs older than the current session at startup; small, safe, but unrequested scope.

---

## (a3) Rounds 5 + 6 — approved final batch, then end-to-end proof (2026-11-02, evening)

Round 5 implemented the four decisions YC had parked, one commit each; Round 6
added integration proof on the Linux server and changed no app source (no real
bug was exposed — the one surprise, `validate()` vs a text-only model, turned
out to be designed behaviour verified against a real server). Full record:
**`AUDIT-ROUND5.md`**. Branch state: **43 commits over base**; final harness
tally **232 executed, 228 passed, 3 skipped (env-gated real-Ollama leg; passes
3/3 when enabled), 1 failure** — the pre-existing SwiftPM bundle-ID artifact in
CaptureScopeTests. Round 4's #32 known failure is fixed, not reclassified.

- **#32 FIXED** (`4120e4f`) — `CLIPrompt.fit` reserves the truncation marker's
  estimated cost (worst case priced per cut, marker text single-sourced in
  `ContextCapture.omissionMarker`); the locale-dependent characterization
  test is now a passing invariant in both estimation paths (harness 19/19).
- **#52 IMPLEMENTED** (`25f04ec`) — `StreamByteBudget`: 32 MiB cumulative cap
  on cloud streams, overflow → the total-too-large network error; the #10
  sibling message was found missing from the catalog and both keys were added
  (781 keys, zh-Hant drafts still `needs_review`).
- **#5 FIXED** (`c6dc30f`) — wipe is a true factory reset over all 41
  AppSettings keys (`K.all`); absent-vs-empty settled reader-by-reader;
  Settings copy updated to match exactly (catalog 784 keys); wipe tests 4/4.
- **Settings window resizable** (`e510ef0`, CI-pending) — `.contentMinSize` +
  min-frame 620×520 floor, the app's own pattern.
- **#24 DONE** (`d355763`) — `.fable/` untracked + ignored; files remain on
  disk byte-identical.
- **Round 6** (`d7473d3`, tests only) — 28 harness tests: fake cloud
  (URLProtocol) incl. hostile set + 200-request soak (0.10 s), real-socket
  Python server + Ollama probe shapes, executable CLI fakes for all three
  providers (incl. the #36 grandchild repro at provider level), and a real
  local Ollama 0.40.13 + qwen2.5:0.5b (397 MB) leg: probe + streamed answer
  through app code, measured cold load 5.74 s total (2.40 s server load),
  warm TTFT ≈ 0.10 s, ≈ 16.1 tok/s median on this 4-CPU VM. NVIDIA NIM leg:
  auth/catalog verified (85 models), generation 404 — account has no
  entitled function; recorded as ready-but-unrun, not a code issue.
- Still open, unchanged: #53 proposal (temp-dir sweep), #31 (zh-Hant in-app
  pin, after native review), #15/#12/#20/#21 (Mac-side refactors/profiling),
  #26 (repo topics — needs a settings write). Notarization is closed by
  YC's decision (no Apple Developer account; do not re-raise).

## (a4) Round 7 — first macOS CI run and its fixes (2026-11-02, later)

PR #3's first CI run (macos-15 + macos-14 jobs) executed 210 tests with 4
failures, all in tests, none in app code — the build (incl. the notes panel)
compiled clean on both runners. Root causes, both test-engineering flaws the
Linux harness could not see:

1. **Stale repo test copy (#32):** the round-5 fix commit updated the harness
   copy of `TruncationCharacterizationTests` (old characterization test ->
   marker-reserve invariants) but the `WispTests/` copy kept the pre-fix
   characterization test, which asserts the buggy behaviour and now fails
   against the fixed code. Fix: repo copy synced to the harness copy.
2. **Locale-pinned expectations (SSE):** `SSEFuzzTests` pinned the Chinese
   source strings of two `String(localized:)` outputs (the in-stream
   `[服务端错误]` prefix and the `服务端没有返回说明。` fallback). On the
   zh-locale Linux host the localized call returns the source string, so the
   tests passed; on en-US macOS runners the app correctly returns the English
   translation and the tests failed. Fix: expectations now derive through the
   same `String(localized:)` the app uses, in both test copies — parsing
   behaviour (precedence, prefix plumbing, interpolation) is still asserted
   exactly, on any locale. (A fifth case of the same flaw,
   `CappedDataBufferBoundaryTests.testMidScalarTruncationMakesRawErrorBodyUnreadable`,
   was fixed in the same pass.)

Lesson recorded: harness copies and `WispTests/` copies must be edited in
lockstep; a harness-only test edit is exactly how (1) happened.

Round-7 correction (from the same raw logs): the macos-14 job's failures in
rounds 1-3 were NEVER test failures. Its log shows xcodebuild exit 74 before
any test ran: "The project 'Wisp' cannot be opened because it is in a future
Xcode project file format (77)" — XcodeGen 2.46 emits the Xcode 16 project
format, and the macos-14 image's default Xcode is 15.4. Every test failure
counted above happened on the macos-15 job alone. Fix: the macos-14 job now
selects the newest Xcode installed on its image before generating; the
tests still execute on macOS 14, which is the coverage the job exists for
(issue #18). With that, round 3's macos-15 job was fully green (210 tests)
and round 4 is the first time the macos-14 job can run at all.

Round-7 correction, part 2: letting the macos-14 job open the project was
not enough — package resolution then failed because KeyboardShortcuts
2.4.0 (the exact pin from #22) declares Swift tools 6.1, and the newest
Xcode installable on the macos-14 image is 16.2 (tools 6.0). The pin is
now 2.3.0 (tools 5.11; still an exact pin, so #22's supply-chain property
holds), and the single 2.4.0-only API the app used —
`KeyboardShortcuts.removeHandler(for:)`, called from
`QuickCommandStore.registerShortcuts()` — was designed out: each
shortcut name now installs one handler for the life of the process that
resolves its command by name at press time (a name is a pure function of
the command ID), and deletion paths already reset the recorded shortcut,
which is what unregisters the system hotkey. All other KeyboardShortcuts
APIs Wisp calls were verified present in the 2.3.0 sources.


---

## (b) Commits on `fix/audit-2026-11-02`

| Hash | Subject | Issues |
|---|---|---|
| `980cdc2` | Add en and zh-Hant InfoPlist.strings for permission dialogs | #1 |
| `f5bee43` | Fix release checksum commands so the .sha256 verifies after download | #2 |
| `facccbf` | Stop pretty-printing the conversation store file | #3 |
| `0763e96` | Correct update-check comments: the request does carry a version UA | #4 |
| `99cda6e` | Correct wipeLocalData comment to match what it actually removes | #5 (partial) |
| `e5ef22e` | Write NBSP/ZWSP in page-text regexes as explicit unicode escapes | #6 |
| `2281ce2` | Cap cloud streaming: error-body + SSE line limits (round 2) | #10 |
| `9aac158` | Cap CLI stderr: one shared 256 KiB DrainBuffer (round 2) | #11 |
| `72cac25` | Unify CLI wall-clock timeouts at 300 s (round 2) | #13 |
| `9465b06` | Derive cloud User-Agent from bundle version (round 2) | #14 |
| `36555f6` | CStringPool: graceful failure instead of strdup force-unwrap (round 2) | #25 |
| `5fd3cf8` | Cap CLI JSON line accumulation at 16 MiB (round 2) | #27 (new) |
| `3d5af10` | CI: add macos-14 job (round 2) | #18 |
| `3c30b64` | Pin KeyboardShortcuts exactly at 2.4.0 (round 2) | #22 |
| `377f6cc` | DRAFT zh-Hant localization, machine-converted, needs native review (round 2) | #9 |
| `eeb8dbd` | Codex app-server clientInfo version from bundle (round 2) | #28 (new) |
| `84e448c` | Correct stale update-check comment in AppDelegate (round 2) | #29 (new) |
| `c6f11ce` | Add recording notes panel (round 3) | feature |
| `31f89d0` | Add Linux test harness: 98 tests run for real (round 2) | scaffold |
| `c63d75e` | Add round-4 fuzz and characterization test suites (audit lane 4) | tests |
| `abc5d96` | Same-second backup collision: retry with suffixes, block if backup fails | #33 |
| `0c7cb14` | Block on a present-but-undecodable schema version instead of loading as v1 | #34 |
| `74b792f` | Surface conversation-store read/write failures instead of losing data silently | #35 |
| `18948a3` | Clamp the numeric settings at the getter, not just the floor | #44 |
| `c0dd4cc` | Never evict the conversation currently streaming | #45 |
| `2fdcdcd` | Deduplicate conversation and message IDs on load, first copy wins | #49 |
| `cafe2e4` | Decode streamed lines lossily so one corrupt byte cannot erase a line | #51 |
| `ce5a0ce` | Scope #51 to the splitter; keep errorMessage's established strict decode | #51 (scope) |
| `51abc3f` | Ollama probe: unrecognised /models shape is a failure, not "running, zero models" | #50 |
| `993e939` | Quick commands: a corrupt stored blob is surfaced and never silently overwritten | #48 |
| `147e199` | Claude CLI: launch inside the RunBox lock, closing the cancel race | #37 |
| `5c470b2` | runAppleScript: synchronized output box, and a pipe wait timeout is a failure | #47 |
| `86651a9` | Bound every CLI read: poll slices and snapshot returns, never a naked EOF wait | #36 |
| `ee02135` | Cap the three small-body reads and share one cloud URLSession | #38, #46 (+#10, #30) |
| `5ebd5c1` | Debug dump needs an in-app arm file, not just a defaults bool | #39 |
| `b74b743` | Check every Keychain result the user can act on | #43 |
| `64f6fbb` | Capture generations: stale captures land nowhere | #40, #41, #42 |
| `4120e4f` | Make CLIPrompt.fit reserve the truncation marker's own cost | #32 |
| `25f04ec` | Add a cumulative byte budget for cloud streams | #52 |
| `c6dc30f` | Make wipeLocalData a true factory reset over all settings keys | #5 |
| `e510ef0` | Let the Settings window resize (620×520 becomes the floor) | round-5 batch |
| `d355763` | Untrack .fable/ agent work notes | #24 |
| `d7473d3` | test: round-6 end-to-end suites in the Linux harness | round 6 |

All round 1-6 commits were local until 2026-11-02 evening, when the branch (44 commits incl. the audit-records commit) was pushed and PR #3 opened. `AUDIT-FIXES.md` (this file), `AUDIT-ROUND2.md`, `AUDIT-ROUND4.md`, `AUDIT-ROUND5.md`, `COVERAGE.md` and `CODE-REVIEW-2026-11-02.md` are intentionally left uncommitted. Round-2 record: `AUDIT-ROUND2.md` (incl. the #8 onboarding design spec — design only, not implemented — and the Round-3 performance/UI review + feature-gap proposals #30–#32).

---

## (c) Risk register

### Security / privacy
- **Ad-hoc code identity (from #7):** beyond permission re-grants, an unsigned/unnotarized download trains users to bypass Gatekeeper — the exact habit phishing copies of the app would rely on. The correct sha256 exists but, until fix #2, the documented verification flow failed for normal users, so in practice almost nobody could verify.
- **Plaintext local archive (#16):** conversations contain *other apps'* content (page text, selections) plus listening transcripts/audio. `0700` directory + Keychain-held API keys are solid baseline hygiene; the gap is purely device-compromise/backup exposure. Same-user processes are explicitly out of the current model (the code says so).
- **User-configured endpoints (#10, #14):** custom base URLs are a feature; the code's defenses there are genuinely strong (HTTPS enforced except loopback, credentials-in-URL rejected, redirects refused so `Authorization` can't leak, ephemeral cookie-less sessions). Residual risks are the unbounded reads (#10) and the stale UA (#14), not credential leakage.
- **User-supplied native models (#17):** sherpa-onnx parses files the user obtained elsewhere; provenance guidance is the only missing layer.
- **CLI providers as attack surface:** reviewed — processes are spawned with argument arrays (no shell), `--restricted`/`--tools Read` for Claude, per-request `0700` temp workspaces for screenshots, watchdogs with SIGTERM→SIGKILL escalation. No issue found; residual risk is inherent to running third-party CLIs under the user's own login.

### Data loss
- **Conversation store:** the strongest part of the codebase — atomic tmp+replace writes, corrupt-file backup with a 3-copy cap, and a newer-schema file forces the app read-only instead of overwriting it. Real residual risks are performance-shaped (#15 full rewrites) rather than corruption-shaped.
- **Listening records:** admission-controlled (2 GiB / 100 sessions, `ListeningTranscript.swift:270–300`), fail-closed, symlink-aware, never auto-deleted ("旧记录不会自动删除"). The failure mode is a hard stop mid-meeting when the budget fills — annoying, not lossy.
- **Wipe semantics (#5):** "delete all data" currently leaves settings/endpoints behind (privacy surprise, not data loss) and — the flip side — `deleteAll()` in the store correctly unblocks persistence even when a newer-version file had blocked writes, so a wipe can't silently fail to stick.

### UX / adoption
- **The install funnel is the product's biggest risk cluster:** ~101 MB download (#20) → Gatekeeper warning + permission re-grants on every update (#7) → Chinese-only permission prompts for non-Chinese users (#1, fixed) → checksum flow that failed when followed (#2, fixed) → no onboarding once inside (#8). Measured context (first pass, Nov 2): ~169 stars vs 39 total release downloads, v0.4.0 at 36 — attention exists; conversion is what's leaking.
- **Traditional Chinese audience (#9):** the README speaks to them, the app doesn't (yet) — for this project's actual community that's a first-class gap, not a nice-to-have.
- **Update check** is opt-in and off by default (`AppSettings.checkForUpdates` default false, `PRIVACY.md` discloses the UA) — good practice; combined with #7 it also means many users will simply stay on old versions, so per-release notes matter more than usual.

### Maintainability
- **File-size concentration (#21)** and **inconsistent timeouts (#13)** are slow-burn costs; both are cheap to address opportunistically.
- **Threading model debt (#12):** the blocking-read pattern works today because every loop is paired with a kill-the-process watchdog; it's the kind of thing that breaks subtly when a fourth provider copies the pattern.
- **Pinning policy (#22) and committed team ID (#23)** are friction for the second contributor who doesn't exist yet — worth fixing before they arrive, not urgent before.
- **Tracked agent notes (#24)** will keep growing unless a decision is made.
- **Positive:** the string catalog is unusually well kept (Appendix A), comments explain *why* at a level most projects never reach, and threat models are written down for the scary features (diagnostics gating, CLI workspaces).

### Release / distribution
- **No automated minimum-OS coverage (#18)** while advertising macOS 14 support; **Intel slice unverified (#19)** while advertising "universal". Both are claim-vs-evidence gaps of the same shape: the marketing line is ahead of the test matrix.
- **Release process is manual and README-driven** — no release script exists, which is how #2 happened. A `tools/release.sh` that builds, zips, checksums (bare filename), and prints the verification commands would retire a whole class of release-day typos. (Proposal; writing it is safe, but it can only be *trusted* after one real release run on a Mac.)
- **Discoverability (#26)** and download counts suggest distribution, not features, is the current bottleneck.

---

## Appendix A — Checked and cleared (first-pass claims that did NOT survive verification, and other near-misses)

Being precise here matters more than padding the issue count:

1. **"Several menu strings bypass localization" — mostly false.** The first-pass review flagged e.g. `WispApp.swift`'s `"\(count)/\(max) 个对话"` menu item. Verification: SwiftUI treats interpolated literals as `LocalizedStringKey`s, and the catalog *contains* the format keys (`%lld/%lld 个对话`, `有新版本 %@，去下载…`, `\n\n[服务端错误] %@`, …). They localize correctly.
2. **String-catalog coverage is essentially complete.** All 408 `String(localized:)` call sites in app code were programmatically compared against the 767-key catalog with format-spec normalization: the only two apparent misses are artifacts (a `"\n"` fragment and a keyPath interpolation the checker can't model). All keys have `en`; the 18 keys "missing zh-Hans" are keys whose source text *is* Chinese (zh-Hans is the development language). The real localization gaps are #1 (permission strings) and #9 (no zh-Hant at all) — narrower than first reported, but real.
3. **`CFBundleDevelopmentRegion = zh-Hans` is not itself a bug.** English resources ship and are complete, so the development region only decides fallback ordering among *available* localizations. It changes nothing for en/zh-Hans users.
4. **The update checker's version comparison is correct** — numeric component comparison (`AppLifecycle.swift:183–189`), no lexicographic `0.10 < 0.4` trap. The check is opt-in, off by default, check-only.
5. **`.gitignore` has no material secret-leak gap** — `.env`/`.env.*` (with `!.env.example`), `*.p12`, `*.mobileprovision`, `xcuserdata/`, `*.xcuserstate`, `Build/`, `dist/`, `DerivedData/`, `.DS_Store` are all covered. (The `.fable/` question in #24 is about *tracked* files, not ignore rules.)
6. **Version numbers do not drift:** `project.yml` MARKETING_VERSION 0.4.0 / build 6, CHANGELOG's latest entry 0.4.0 (2026-09-11), `LSMinimumSystemVersion` 14.0 == deploymentTarget 14.0 — all consistent. The one stale version string in the codebase is the hardcoded UA in #14.
7. **Screenshots are not persisted into the conversation file** — `ContextSnapshot` stores scope/metadata only; images live in memory (and in the opt-in debug dump). The plaintext concern in #16 is about text.
8. **Fast/Priority tier preference is disclosed, not hidden** — cloud requests prefer `service_tier: priority`/Fast (`OpenAICompatibleProvider`), and this is stated in the UI (`ResponseModeView.swift:114`) and README ("Fast can consume more credits"). A deliberate, documented product choice; not counted as an issue.
9. **The first pass's "no integrity check on downloaded speech models" framing was wrong in an important way:** Wisp downloads nothing — models are user-placed files, and Wisp structurally validates the ONNX container before loading. #17 is the accurate, narrower version.

# Wisp Audit — Round 2 Record

- **Date:** 2026-11-02
- **Scope:** Local clone `~/workspace/wisp-review`, branch `fix/audit-2026-11-02`, on top of round 1 (`e5ef22e`). GitHub remote untouched: no pushes, no API writes.
- **Methodology (per item):** ① 质疑 — worst-case analysis first; ② 复现 — a unit test written *before* the fix at the nearest testable seam (or a written reproduction note where the defect is only observable at runtime); ③ 实现 — minimal fix; ④ 验证 — recorded honestly. There was **no Swift toolchain on this machine** for the macOS target when the round began (one was installed mid-round for Linux only): every test below is "written, CI-pending" unless the Linux harness (see its section) actually ran it, in which case it says so. Nothing in this document claims a test passed that was not run.
- **Companion docs:** `AUDIT-FIXES.md` (round-1 issue list; statuses updated to point here), `COVERAGE.md` (exhaustive coverage pass), `CODE-REVIEW-2026-11-02.md` (first pass).

**Round-2 totals:** 13 commits on the branch (9 fix commits for #9/#10/#11/#13/#14/#18/#22/#25/#27, 2 for new findings #28/#29, 1 feature commit for the Round-3 notes panel, 1 harness commit; the audit docs themselves stay uncommitted). 38 new test methods in WispTests (5 files); 98 tests actually executed in the Linux harness (96 passed, 2 failed — both root-caused, one promoted to finding #32). Coverage: 82 Swift files read, 21,717 lines, 823 `func ` occurrences (COVERAGE.md). New findings #27–#32: 3 fixed (#27, #28, #29), 3 proposed (#30 shared URLSession, #31 zh-Hant language pin, #32 locale-dependent prompt-budget test). Deferred unchanged: #7, #12, #15, #20, #21, #24.

---

## Implemented fixes

### #9 — zh-Hant UI localization: machine-converted DRAFT landed for native review
- **Commit:** `377f6cc` (subject line starts "DRAFT (machine-converted, needs native review)")
- **质疑 (worst case):** A careless conversion is worse than none: wrong regional vocabulary （內存 vs 記憶體， 信息 vs 資訊） reads as machine-translated junk to exactly the audience the project courts, and a conversion that mangles a format specifier (`%@`, `%lld`) crashes or garbles UI at runtime. Both failure modes are addressed mechanically below; the residual risk is tone/terminology judgment, which no tool here can clear — hence DRAFT.
- **复现 (reproduction):** The gap itself: a programmatic language audit of `Localizable.xcstrings` showed exactly two languages across 767 keys (`en` ×767, `zh-Hans` ×749 + 18 source-key fallbacks), while `README.zh-TW.md` markets to Traditional readers (round 1, #9 evidence).
- **实现 (fix):** OpenCC `s2twp` (installed into a throwaway venv at `/tmp/wisp-venv`; the `opencc` binary was absent) converted every key's zh-Hans source value (or the key itself for the 18 source-fallback entries) into a new `zh-Hant` localization, each marked `state: needs_review`. Result: 684 values changed, 83 byte-identical (no convertible characters — format strings and neutral text). `project.yml` adds `zh-Hant` to `CFBundleLocalizations` so the draft is selectable in the running app. Disclosure: the scripted JSON rewrite normalized ~194 entries Xcode had written in compact one-line form into the file's dominant expanded style.
- **验证 (verification):** Mechanical, and actually run here: catalog re-parsed as JSON; key set **and order** identical to the pre-conversion file (compared against `git show HEAD~1:`); per-key format-specifier multisets identical between source and conversion (**0 mismatches**); en and zh-Hans values verified **byte-identical** to before (0 diffs). What remains unverified is everything human: terminology choices, tone, and in-app rendering — the commit is a review starting point, not finished localization. CI-pending for the build itself.

### #18 — CI now builds and tests on macos-14, the minimum supported OS
- **Commit:** `3d5af10`
- **质疑 (worst case):** The support promise (deploymentTarget 14.0, LSMinimumSystemVersion 14.0) had zero automated evidence: any macOS-15-only API call compiles green on the macos-15 runner and crashes a 14.0 user at launch — the exact users least able to diagnose it.
- **复现 (reproduction):** Not a code defect; the reproduction is the absence itself — `.github/workflows/ci.yml` contained exactly one job, `runs-on: macos-15`. Recorded by reading the file (round 1, #18 evidence).
- **实现 (fix):** Added `test-and-release-check-macos-14` mirroring the existing job step-for-step (checkout, XcodeGen, generate, unit tests, dual-arch Release build, signature/entitlement verification) on `runs-on: macos-14`, with a comment stating why it exists.
- **验证 (verification):** YAML parsed with PyYAML after editing (both jobs present, 6 steps each) — that is the only verification possible here; the job's first real run is **CI-pending** (branch unpushed, per constraints).

### #22 — KeyboardShortcuts pinned exactly at the resolved 2.4.0
- **Commit:** `3c30b64`
- **质疑 (worst case):** A future `xcodegen generate` + resolve on a maintainer machine silently lifts the global-hotkey library from 2.4.0 to the newest 2.x, changing hotkey behaviour in a release nobody meant to touch. Committed `Package.resolved` blunts this today, but the range in `project.yml` is the standing invitation.
- **复现 (reproduction):** `project.yml` declared `from: 2.2.1` while `Package.resolved` pins 2.4.0 — the drift window is visible by reading the two files side by side (round 1, #22 evidence).
- **实现 (fix):** `from: 2.2.1` → `exactVersion: 2.4.0`, matching SherpaOnnx's pinning style in the same file and the already-resolved version, so no dependency resolution result changes.
- **验证 (verification):** `project.yml` re-parsed with PyYAML (pin reads back as exactVersion 2.4.0). The project was **not** regenerated (needs XcodeGen on a Mac); CI runs `xcodegen generate`, so the pin is exercised on the next CI run — **CI-pending**.

### #27 (new in round 2) — CLI stdout line framing was unbounded, same pattern as #11
- **Commit:** `5fd3cf8`
- **Evidence:** `CLIJSONLines.append` (`CodexCLIProvider.swift`) accumulated into `buffer` until a `0x0A` appeared, with no size check — used by both AGY and Codex stream loops. Claude's provider has its own inline version of the same loop (`ClaudeCodeCLIProvider.swift`, the `buffer.append(chunk)` NDJSON framing). Round 1's #11 caught the stderr side of this pattern and missed the stdout side.
- **质疑 (worst case):** A CLI that emits one endless line (corrupt output, a binary blob treated as text, a progress spinner without newlines) grows the buffer until the 300 s watchdog kills the process — same memory shape as #10/#11, through the front door.
- **复现 (reproduction):** `CLIJSONLines` is a testable struct. `WispTests/CLIJSONLinesTests.swift` pins existing framing behaviour first (in-order parse, partial line held across chunks, EOF flush of the trailing partial line, whitespace-only lines skipped, invalid JSON throws) and then the new cap: single line past 16 MiB throws, residual growing past the cap across 1 MiB chunks throws, a valid line just under the cap parses.
- **实现 (fix):** `CLIJSONLines.maxLineBytes = 16 MiB` (a result event carries the full answer text, so this is deliberately generous); `append` throws `ProviderError.network("Oversized CLI JSON event")` when either an extracted line or the residual partial line exceeds it. Claude's inline loop guards its residual against the same constant with the same error. Claude's guard is not unit-testable (it lives inside the process-stream closure) — inspection-verified only, stated plainly.
- **验证 (verification):** Tests written, since **run green in the Linux harness** (CLIJSONLinesTests, 8 tests) for the Codex half; inspection-only (Claude inline half). macOS CI-pending.

### #25 — CStringPool: strdup failure is a load failure, not a crash
- **Commit:** `36555f6`
- **质疑 (worst case):** `strdup` returns nil only under memory exhaustion — exactly the moment a crash dump is least affordable and least diagnosable. The subtler failure the fix must avoid: silently substituting an empty string and letting recognizer creation proceed against empty paths, producing either a baffling native error or, worst case, a recognizer built from defaults. So the fix has two halves: never crash, and never let a degraded config through unnoticed.
- **复现 (reproduction):** A unit test cannot make `strdup` fail on demand, so the reproduction is a written one: pre-fix, `LocalSpeechModel.swift`'s `CStringPool.callAsFunction` was `strdup(string)!` — nil in, process dead, no error path. The testable seam is the pool's contract, pinned by `WispTests/CStringPoolTests.swift`: contents round-trip, pointers stay valid after 64 further appends (the pool's raison d'être), distinct strings get distinct storage, missing-role `path` resolves to `""`, present-role resolves to the file path, and `allocationFailed` stays false in normal use.
- **实现 (fix):** `callAsFunction` now guards the `strdup`: on failure it sets `allocationFailed` and returns a pointer to a one-byte static `[CChar]` storage (process-lifetime address, no further allocation — the one thing guaranteed unavailable in that moment). `LocalSpeechRecognition.create()` checks `!strings.allocationFailed` after `configure(...)` and throws the *existing* `ListeningFailure` load-failure message (same construction as the nil-recognizer guard immediately below it). `path(_:in:)` routes through `callAsFunction`, so it inherits the behaviour. No signature changes; the two families needed no edits.
- **验证 (verification):** Tests written, **CI-pending**; the failure branch is inspection-verified only (stated plainly: it cannot be exercised without fault injection). One formal note: the fallback pointer escapes `withUnsafeBufferPointer`; the storage is a `static let` that lives for the process duration and is never mutated, which is what makes the escape sound.

### #13 — CLI wall-clock timeouts unified at 300 s
- **Commit:** `72cac25`
- **质疑 (worst case):** Not a crash — a consistency trap. A slow Codex run (large screenshot + long page) dies at 240 s while the identical request through Claude or AGY would have completed at, say, 260 s. The user sees one provider "always timing out" and misdiagnoses their Codex install; support time burns on a phantom. Drift is the deeper risk: three literals invite a fourth value next time someone tunes one provider.
- **复现 (reproduction):** Compile-time constants, so the "reproduction" is a pin test: `CLIWallClockTests` (`WispTests/ProviderSharedTests.swift`) assert the shared constant is 300 and all three providers' `wallClockTimeout` equal it. Written against the pre-fix tree, the Codex assertion is the one that fails (240 ≠ 300) — that failure *is* the defect, captured.
- **实现 (fix):** `CLIWallClock.timeout = 300` in `ChatProvider.swift`; each provider's `wallClockTimeout` now aliases it. Error-message shape preserved (`claudeCodeTimedOut(Int(Self.wallClockTimeout))` etc. unchanged), AGY's `--print-timeout` argument follows automatically, and the stale "240 秒线" comment in Codex's watchdog now says "墙钟上限边缘". Verified no other 240 s timeout literal remains in `Wisp/`.
- **验证 (verification):** Tests written, since **run green in the Linux harness** (CLIWallClockTests, 2 tests). macOS CI-pending.

### #14 — Cloud User-Agent derived from the bundle version
- **Commit:** `9465b06`
- **质疑 (worst case):** Every cloud request announced `Wisp/0.1` — a version that never shipped — while the app is at 0.4.0. Some gateways rate-limit or flag stale/unknown agents; more importantly, any provider-side abuse investigation or compatibility decision keyed on UA is working from false data, and the hardcode guarantees it drifts again at 0.5.
- **复现 (reproduction):** `UserAgentTests` (same file as #13's tests): the UA must equal `"Wisp/" + UpdateChecker.currentVersion` and must not equal the stale `"Wisp/0.1"`. The seam is `UpdateChecker.userAgent`, a pure derivation from `currentVersion` — the same source the update checker already trusted.
- **实现 (fix):** `UpdateChecker.userAgent` added in `AppLifecycle.swift`; its own `check()` and `OpenAICompatibleProvider.request(...)` both use it. `grep "Wisp/0"` across `Wisp/` confirms no hardcoded UA remains.
- **验证 (verification):** Tests written, **CI-pending**. Note the test asserts derivation, not a literal version, so it survives version bumps. `currentVersion` reads `Bundle.main`, which under the test host is the app bundle (0.4.0). In the Linux harness the same test ran green against the mirrored `UpdateChecker` accessors (the real ones live in an AppKit file) — the *callers'* derivation wiring is what is verified there; the accessor itself remains CI-pending.

### #11 — CLI stderr cap: one shared DrainBuffer, last 256 KiB
- **Commit:** `9aac158`
- **质疑 (worst case):** All three CLI providers accumulated stderr into a private `DrainBuffer` with no limit for the life of a run. A CLI stuck in an error loop (auth prompts, stack traces) can emit megabytes per second; the watchdog gives it up to 300 s. Secondary worst case, found while designing the fix: the *naive* cap (drop from the head) can cut a multi-byte UTF-8 scalar in half, after which `String(data:encoding:)` returns nil for the *whole* buffer and every error message silently becomes `""` — the cap would have traded a memory bug for an invisible diagnostics bug.
- **复现 (reproduction):** `DrainBuffer` was `private` inside each provider, unreachable from tests. Per the brief, the smallest behaviour-preserving refactor was applied: the three identical copies were deleted and one shared internal `DrainBuffer` now lives in `ChatProvider.swift` (home of the other shared CLI helpers). Tests: `WispTests/DrainBufferTests.swift` — under-cap fidelity, empty text, exact tail retention past the cap, many-small-chunks cap, the mid-scalar trim case (trim removes 4 bytes: one full 3-byte scalar plus the lead byte of the next, leaving two continuation bytes that must be skipped), and the 256 KiB constant.
- **实现 (fix):** `DrainBuffer.append` trims to the last 256 KiB and then skips any leading UTF-8 continuation bytes (`(first & 0xC0) == 0x80`) so `text` always starts on a scalar boundary. Codex's "why stderr must be drained" comment moved from its deleted private copy to the use site in `stream(...)`. All three call sites (`DrainBuffer()`) resolve unchanged to the shared type; locking and the `text` contract are byte-identical to the old copies.
- **验证 (verification):** Tests written, since **run green in the Linux harness** (DrainBufferTests, 6 tests — including the mid-scalar trim case that was hand-simulated at writing time; the simulation was right). macOS CI-pending.

### #10 — Cloud streaming caps (error body 64 KiB, SSE line 1 MiB)
- **Commit:** `2281ce2`
- **质疑 (worst case):** Endpoints are user-configured, so the "server" can be a hostile or broken self-hosted gateway. Before the fix, a non-2xx response was accumulated byte-by-byte with no cap, and `bytes.lines` buffered a single SSE line without bound; a gateway that streams an endless error body — or one data line that never terminates — grows the app's memory for up to the 300 s resource timeout, *per attempt*, and the priority-rejection path retries. On a memory-constrained machine this is an OOM/crash vector triggered by a config value the user pasted.
- **复现 (reproduction):** The defect is only observable against a live misbehaving server, so tests were written at the two testable seams the fix introduces: `CappedDataBuffer` (keeps only the first N bytes, reports truncation) and `SSELineSplitter` (byte-fed line splitter that throws past the cap). Tests: `WispTests/StreamGuardTests.swift` — `CappedDataBufferTests` (under-limit fidelity, exact-limit not truncated, over-limit stops at limit + reports, zero limit, the 64 KiB constant) and `SSELineSplitterTests` (LF/CRLF, blank separator lines, unterminated tail flushed by `finish()`, empty stream, byte-by-byte multi-byte UTF-8 reassembly, line exactly at cap accepted, cap+1 throws `lineTooLong`).
- **实现 (fix):** `OpenAICompatibleProvider.maxErrorBodyBytes = 64 * 1024`; the non-2xx path accumulates through `CappedDataBuffer` and stops reading at the cap (`mapError` only ever reads the head — status line, `error.message`, first 400 chars — so nothing it consumes is lost). The SSE loop no longer uses `bytes.lines`; it feeds `SSELineSplitter` (1 MiB/line) and maps overflow to `ProviderError.network` ("服务端返回的单行数据过长，已中断。"). Behaviour deltas vs `bytes.lines`, deliberately accepted and recorded: (1) lines are delimited by `\n` only, with one trailing `\r` stripped — a lone-`\r`-terminated line is no longer a delimiter (SSE payloads are JSON with escaped control characters, and real gateways terminate with `\n` or `\r\n`); (2) if `[DONE]` and cancellation race, the cancellation now wins (previously the finished answer won) — the stricter reading.
- **验证 (verification):** Tests written, since **run green in the Linux harness**: CappedDataBufferTests (5) + SSELineSplitterTests (8), and the provider's streaming loop itself executed end-to-end there via the ported URLProtocol priority-retry test (transport shimmed, loop verbatim). macOS CI-pending.

---

### #28 (new in round 2) — Codex app-server handshake hardcoded its client version
- **Commit:** `eeb8dbd`
- **质疑：** Same drift class as #14. `AppServerSession.initializeRequest` told the Codex app-server `"version": "0.4.0"` as a literal. It matches today only by coincidence; the next MARKETING_VERSION bump would silently misreport the client version to a protocol peer that may gate behaviour on it.
- **复现：** `AppServerSession.initializeRequest` is a static, directly testable seam (the Codex session state machine already has 35 tests). Test written first: `CodexClientInfoTests.testInitializeRequestReportsTheBundleVersion` in `WispTests/ProviderSharedTests.swift` — pins `clientInfo.version == UpdateChecker.currentVersion`, so a re-hardcoded literal fails the moment the bundle version moves.
- **实现：** `"version": UpdateChecker.currentVersion`. A final grep confirms no other hardcoded `"0.4.0"` / `Wisp/0` literals remain in app sources.
- **验证：** Test written, since **run green in the Linux harness** (`CodexClientInfoTests`) against the mirrored `UpdateChecker` accessor — the payload-side wiring is verified; the accessor itself is CI-pending like #14's.

### #32 (new, found by the Linux harness) — A prompt-budget test that only passes in English
- **质疑：** `CLIPromptTests.testOversizedPromptIsTruncated` asserts a fitted prompt estimates at ≤ budget + 100 tokens. But `CLIPrompt.fit` (ChatProvider.swift) does a single proportional pass and `ContextCapture.truncate` then *appends* a marker whose own token cost is never accounted. Measured with the app's own estimator: the marker costs ~93 tokens when resolved in English and ~107 when resolved in Chinese (the two 24-char samples are wide-script either way; the prose is what changes). The test's slack fits the English marker and not the Chinese one — so the suite is green on an English-locale host (macOS CI) and red on a zh-Hans/zh-Hant host, with nothing in the failure pointing at language.
- **复现：** The Linux harness *is* the reproduction: its `String(localized:)` stand-in returns the Chinese source string, and the test failed there at exactly the predicted margin (3106 vs the 3100 bound; Chinese-marker arithmetic predicts ~3107, English ~3093). Verified numerically against the catalog's en/zh-Hans marker values using the app's estimator ranges.
- **Disposition:** Recorded, **not fixed in this round** — the right fix is a product decision: either `fit` subtracts an estimated marker cost before truncating (behaviour change to prompt fitting; needs the Mac test suite to validate) or the test's bound is made locale-aware. Flagged for YC; the harness keeps the failure visible until then.
- **验证：** Failure reproduced and root-caused; see the harness section.

### #29 (new in round 2) — A third copy of the false update-check privacy claim
- **Commit:** `84e448c`
- **质疑：** Round 1 (#4) corrected "sends no identifying information" in AppLifecycle.swift and AppSettings.swift. The launch-site comment in `AppDelegate.swift` still claimed 只请求一次版本号，不带任何标识信息 — but the check sends a `Wisp/<version>` User-Agent. A privacy claim repeated in three places had already drifted once; the surviving copy would keep telling future editors the wrong fact.
- **复现：** `grep "标识信息"` across the app sources (the round-1 fix sites say 不带其他标识信息； only the AppDelegate copy claimed none at all). Comment-only; no test seam applies.
- **实现：** Comment corrected to match the shipped behaviour and the round-1 wording （只发送 Wisp/<版本> User-Agent，不带其他标识信息）.
- **验证：** By inspection; grep re-run clean.

### #30 (new in round 2, proposal) — Cloud provider builds a fresh URLSession per request
- **质疑：** `OpenAICompatibleProvider` creates its `URLSession` in the provider's initializer, and `ProviderConfig.provider(for:)` constructs a new provider per question — so every cloud/Ollama question pays a fresh TCP+TLS handshake (and loses connection reuse for the whole stream) where a shared session would amortize it. On high-latency links this is a fixed tax on time-to-first-token for the product's most common path. UpdateChecker/OllamaSupport by contrast create one-shot sessions and invalidate them — appropriate for probes, wrong shape for the hot path.
- **Reproduction note:** Traceable in code: provider construction in `AssistantModel.streamAnswer` → `ProviderConfig.provider(for:)` per send; session stored per-instance. No runtime measurement possible here; on a Mac, Instruments' Network template (or counting `__nw_connection` creations per question) settles it in one run.
- **Proposal (not implemented — behaviour-adjacent, needs a Mac to verify no delegate/lifecycle regression):** hoist one shared `URLSession` (same configuration) to a static on `OpenAICompatibleProvider`, keep per-request state on the request. Small diff, but session lifecycle + the existing cancellation path (`session?.invalidateAndCancel` semantics in validate) must be re-checked on a real build.
- **Verification:** Proposal only this round.

---

## #8 — Onboarding design spec (not implemented)

**Problem (from round 1):** a fresh install cannot answer anything until the user discovers Settings and configures a provider + API key (or installs a CLI). The panel opens, the user asks, and the first experience is a configuration error.

**Entry condition (derive, don't store):** show the sheet when *no* usable provider exists, computed from existing state — no new "hasOnboarded" flag to drift out of sync:
- Cloud selected and `KeychainStore.load(for: settings.cloudProvider) == nil` (or the selected base URL is empty), **and**
- Ollama not running (`OllamaSupport.probe` ≠ `.running`), **and**
- No CLI resolves (`ClaudeCodeCLIProvider.resolvePath` / `CodexCLIProvider.resolvePath` / `AgyCLIProvider.resolvePath` all nil for the configured paths).
Trigger points: first panel open after launch, and whenever a question is submitted while the condition holds (intercept before the provider call, replacing today's bare `ProviderError.missingKey` dead end).

**Flow (one sheet, three rows, each independently completable):**
1. **Cloud API** — provider picker (reuse `CloudProvider` presets + base-URL/model fields from Settings), key field writing through `KeychainStore.save`, and a **Test connection** button that calls the existing `OpenAICompatibleProvider.validate(config:)` (it already sends the tiny test image and maps every failure to a readable `ProviderError`). Success collapses the row to a green check with the provider name.
2. **Local CLI** — for each detected CLI (`detectedPath != nil`) show "Use Claude Code / Codex / AGY" one-click rows that set `settings.providerKind/cliProvider`; undetected ones show their install hint text (the strings already exist in `ProviderError` descriptions). Validation reuses each provider's `validate(config:)` (auth status / `--version`).
3. **Ollama** — if `probe` reports `.running`, a one-click row; if installed but stopped, a "Start Ollama" button wired to the existing `OllamaSupport.startServer()`; otherwise the install URL.
Footer: "Skip for now" (dismisses; the sheet re-offers on the next failed ask, not on every launch — annoyance budget), and a link that opens the full Settings window for everything else.

**Reuse, not duplication:** all validation goes through the existing `ChatProvider.validate(config:)` protocol methods; all persistence goes through `AppSettings` + `KeychainStore` exactly as Settings does, so onboarding and Settings can never disagree about what "configured" means. The sheet must *not* grow its own copy of the provider fields — extract the cloud-config section of `SettingsView` into a subview both can host (this also starts the #21 split along a natural seam).

**Files it would touch:** new `Wisp/UI/OnboardingView.swift` (sheet + row views); `Wisp/UI/AssistantModel.swift` (evaluate the entry condition on first ask / panel open, present the sheet); `Wisp/UI/SettingsView.swift` (extract the cloud-config section into a shared subview); `Wisp/Support/AppSettings.swift` (no new keys needed — condition is derived); string catalog additions for the sheet's copy (en + zh-Hans, zh-Hant via the #9 draft pipeline). **Verification it needs:** fresh-profile manual pass on a Mac (delete app support dir + keychain items, first-launch walkthrough for each of the three paths), plus a unit test for the entry-condition derivation if it is factored as a pure function of settings/keychain state — factor it that way.

**Explicit non-goals:** no account creation, no bundled API keys, no telemetry on completion, no multi-page wizard.

---

## Deferred with reason (need a Mac to verify / owner's call)

- **#7 Notarization** — needs YC's paid Apple Developer account and identity decision. Not code.
- **#12 CLI read loops on cooperative-pool threads** — threading-sensitive refactor (move blocking `availableData` loops to a dedicated queue). Behavior-preserving on paper, but a mistake here deadlocks or double-delivers; must be verified with the CLI provider tests + cancellation-latency checks on a Mac. Deferred.
- **#15 Conversation persistence architecture** (debounce / off-main encode / per-conversation files) — needs Mac profiling with a max-size fixture to prove the hitch exists and that the fix removes it; landing it blind risks the store's currently-excellent corruption behaviour. Deferred.
- **#20 Binary size (~101 MB)** — composition unmeasured; requires Mac-side link map / `size -m` before any stripping or dynamic-linking decision. Deferred.
- **#21 SettingsView split (1,974 lines)** — pure refactor, but a 20-file diff that cannot be compile-checked here; a single mis-moved symbol breaks the build silently. Deferred until it can be paired with a Mac build.
- **#24 `.fable/` tracked work-notes** — YC's decision (transparency vs hygiene). Untouched.

---

## Legacy / history verification

The old code was audited, not just HEAD: `git log` fix/hotfix commits and CHANGELOG "fixed" claims were spot-checked against the current tree. Verdicts below; every claim checked held up — the changelog is trustworthy, which is itself a finding worth recording.

### Historical "fixed" claims — spot-checked

| # | Claim (source) | Verdict | Evidence in current code |
|---|---|---|---|
| 1 | "Privacy cursor lock is no longer disabled when window hiding is off" (CHANGELOG, 0.4.0; commit `858d457`) | **Verified fixed** | `ScreenPrivacy.apply(to:)` special-cases `CursorSharingSurface` windows regardless of the hide toggle ("Never expose the private moving arrow, even when window hiding is off"); `AppSettings` couples the flags both ways (enabling cursor lock force-enables hide; disabling hide force-disables lock); `AppDelegate.configureLocalCursor()` requires both. |
| 2 | "Claude Code can no longer turn a partial stream into a successful saved answer" (CHANGELOG ~0.2.x) | **Verified fixed** | `ClaudeCodeCLIProvider.isSuccessfulCompletion` = `status == 0 && outcome?.isError == false`; the stream-end guard throws `claudeCodeFailed` otherwise, and `AssistantModel` discards empty answers instead of saving them. |
| 3 | A conversation file written by a newer Wisp is never overwritten by an older one (CHANGELOG) | **Verified fixed** | `ConversationStore.load()` decodes `ConversationFileVersionProbe` first; a newer version sets `persistenceBlocked = true` + `LoadIssue.newerVersion`; the only escape is the explicit user action `archiveBlockingFileAndReset()`. |
| 4 | Codex completions landing exactly on the timeout boundary are not misreported as timeouts (CHANGELOG) | **Verified fixed** | `RunBox.stop(onlyIfRunning:)`; the watchdog calls `box.stop(.timedOut, onlyIfRunning: true)`, with a comment describing exactly this boundary case. |
| 5 | Per-provider Keychain keys + migration of the 0.2.x single key (CHANGELOG, 0.3.0) | **Verified fixed, in full** | `AppDelegate` calls `KeychainStore.migrateLegacyKeyIfNeeded { AppSettings.shared.adoptLegacyCloudConfig() }`. `adoptLegacyCloudConfig()` reads the **persisted** `d.object(forKey: K.baseURL)` (not the registered default — the subtlety the changelog itself calls out) and pins `legacyDefaultBaseURL`/`legacyDefaultModel` when nothing was persisted. Migration is lazy: fresh installs are untouched. |
| 6 | "Local models no longer transcribe silence" (CHANGELOG) | **Verified fixed** | `LocalSpeechRecognition.isSilent` peak gate rejects all-quiet batches before any recognizer work. |
| 7 | English build once sent a Chinese system prompt because the catalog key carried one trailing newline the source lacks — "fixed in 0.2.0, reintroduced, fixed again" (CHANGELOG) | **Verified fixed (checked mechanically)** | The `PromptBuilder.systemPrompt` multiline literal was extracted from source and compared char-for-char: the exact string (no trailing newline) exists as the **sole** catalog key, the zh-Hans value equals the key, and the en value is a clean translation. No near-duplicate key with a trailing newline exists. |

### Regression-prone patterns history suggests

- **(a) Localization key exactness.** The trailing-newline incident happened *twice*. `String(localized:)` with multiline literals makes the source text itself the key, so any invisible-byte drift (see round-1 #6's NBSP/ZWSP) silently forks the key. No automated guard exists; a cheap one is proposed in the feature-gap list (a CI lint that every `String(localized:)` literal exists verbatim in the catalog).
- **(b) Screen privacy / cursor.** 4 of the ~26 pre-audit commits touch this area (`f602063`, `4044566`, `17999d2`, `858d457`) and five dedicated probes live under `tools/screen-privacy/`. Highest-churn, highest-subtlety surface in the app; any change here should be required to re-run the probe suite on a Mac.
- **(c) Release packaging is manual and keeps biting** — `ditto --sequesterRsrc`, the get-task-allow CI gate, commit `51be5d2` (CI release-path fix), round-1 #2 (checksum flow). Each release re-derives steps a script should own; the durable fix is #7's notarization work plus a scripted release checklist, not more care.
- **(d) CLI read loops.** Repeated historical fixes around process-stream draining and completion detection (claims 2 and 4 above) corroborate round-1 #12's concern: this is the area where behaviour is easiest to break silently, which is why #12 stays deferred until it can be verified on a Mac.

### Intentional legacy vs accidental leftovers

Kept on purpose — do not "clean up":
- `KeychainStore.legacyAccount = "api-key"` — the 0.2.x migration source (claim 5).
- `AppSettings.legacyIslandOrigin` — migration-only reader for the 0.2.0 island anchor (window origin → dot-centre conversion in `IslandController.migrateLegacyAnchorIfNeeded()`).
- `ResponseMode.standard` — retained as a decoding/migration value; `allCases = [.quick, .deep]` and stored `standard` values map to `.quick`.
- `PanelController.legacyCollapsedHeight = 180` — frame-restore migration in `restoreStoredFrame()`.
- `LocalSpeechCatalog.legacySenseVoiceID`, `ListeningPreferences`' `senseVoiceLanguage` coding key, `ListeningEngine`'s `"senseVoice"` raw value — the 0.3 single-model era's persisted shapes, each with a comment saying so.
- CHANGELOG line ~418's stale "It sends nothing about you or your usage" — a historical entry about a past release; round 1 deliberately left history unedited (current docs — PRIVACY.md, AppLifecycle, Settings copy — all state the real behaviour).

Accidental leftovers found and handled this round: #28 (stale version literal), #29 (stale privacy comment). No dead code paths contradicting current behaviour were found in the coverage pass.


---

## Round 3 — against the stated goal: lightweight, fast-starting, simple

### A. Performance audit (traced in code; no Mac profiling available here)

**Launch path** (`AppDelegate.applicationDidFinishLaunching`). Synchronous work before idle: `KeychainStore.migrateLegacyKeyIfNeeded` (steady state = one not-found `SecItemCopyMatching`, milliseconds; only the first post-0.3 launch does real migration work). Screen-recording permission is *requested* only if missing, and dispatched async. The MainActor block runs `WispCursorPolicy.install()` (method swizzling, one-time, trivial), `ScreenPrivacy.start()` (window observation), `PanelController.restoreStoredFrame()` (reads one defaults string), `IslandController.start()`. The update check is opt-in (default **off**) and async. **No provider probes, no CLI spawns, no model scans at launch.** One real cost: `ConversationStore.shared.load()` decodes the *entire* conversations.json on the main actor the first time anything touches the store (menu, settings, panel all do) — bounded by the store's own caps (50 conversations × 200 turns), worst case a few MB of JSON; this is the #15 family, deferred there. Verdict: launch is genuinely light; nothing found that contradicts "fast-starting" except the store decode, already tracked.

**Per-question spawns — the headline metric:**

| Path | Processes spawned per user question | Notes |
|---|---|---|
| Cloud (OpenAI-compatible) | **0** | But a fresh `URLSession` per request — fresh TCP+TLS each time (#30, proposed). |
| Ollama | **0** | Same HTTP path. `probe()` runs only from Settings/menu appear (60 s staleness throttle in `ModelMenuState`), never per question — verified in `AssistantModel`. |
| Codex | **1** | The app-server process. Path resolution is file-existence checks only. |
| Claude | **1** | The CLI process. Existence checks only. |
| AGY | **1–2** | The CLI process, plus — when more than one install exists — `latestDetectedPath()` runs `agy --version` on **each candidate on every request**. Deliberate no-cache freshness trade-off (comments argue it), but it is the one avoidable spawn on a hot path. **Proposal:** cache the winning path keyed on candidate mtimes; invalidation is free (mtime change = new install). Not implemented: changes detection semantics, needs a Mac to verify against real multi-install machines. |
| Capture (deep mode only) | **~2–63** | One `osascript` process per AppleScript call: basic info (1) + beginJS (1) + up to 60 scroll steps (~250 ms each, 18 s total budget, documented in code) + finishJS (1). Quick mode: 0–1. This is the dominant per-question cost in the whole app — and it is *inherent to the chosen mechanism* (Apple Events JS has no persistent channel) and only paid when the user asks a deep question about a browser page. The 1 Hz front-window poll is `CGWindowListCopyWindowInfo` (no spawn); the follow-up header fetch spawns only when the window title actually changed. |

Also traced: `runAppleScript` busy-polls with `usleep(20_000)` on a global-queue thread while the script runs (wastes a cooperative thread for up to seconds during scroll collection) — #12 family, deferred with it. Prompt assembly is string concatenation over capped inputs (page text ≤ user limit, transcript ≤ 12,000 chars into drafts) on the main actor — bounded and small. Screenshot JPEG comes from ScreenCaptureKit already encoded; no extra encode pass found.

**Idle cost.** No repeating timer runs while truly idle: PanelController's timers are one-shot (idle-dismiss; 0.2 s frame-save debounce); the 1 Hz front-window follow timer exists **only while the panel is visible**; the 60 Hz cursor timer exists **only while the experimental cursor lock is on**; ListeningModel's 2 s checkpoint timer exists **only while recording**; PushToTalk's 60 s timer is one-shot. `TimelineView` refreshes (30 s header age, 1 s recording elapsed) are view-local and cheap. The update check never polls. Verdict: idle Wisp is as close to free as a menu-bar app gets.

**Fixes landed from this audit:** none beyond #30's proposal and the AGY path-cache proposal — the traced costs are either inherent (AppleScript mechanism), already bounded, or need a Mac to verify. Recorded honestly rather than "optimizing" blind.

### B. UI/UX design review (designer pass; severities relative to "simple little tool")

Surfaces reviewed: menu-bar menu, main panel (header/composer/message list/empty state), conversation list, transcript page, island (bottom + notch), settings (all 8 tabs), model switcher, response-mode UI, quick-command editor, and (new) the notes panel.

- **Steps to first answer — good, with one cliff.** Hotkey → panel → type → Return. The empty state pre-loads quick-command chips, so a first question can be one click. The cliff is the unconfigured first run (#8, spec written, not built): a new user hits a provider error with no guided path. *Severity: high for adoption, already tracked.*
- **Settings breadth is the simplicity outlier.** 1,974 lines present **8 tabs, 26 sections, 12 toggles, 14 pickers, 7 shortcut recorders, 67 buttons**. The information architecture itself is sound (model/panel/commands/capture/audio/privacy/data/general is the order a user thinks in, and explanatory copy is consistently folded into ⓘ popovers instead of walls of text), but the *provider matrix* (3 connection kinds × per-provider fields × per-mode model overrides) is intrinsically the app's complexity budget. Nothing here is redundant; the risk is first-run intimidation, which #8's guided subset addresses better than cutting settings would. *Severity: medium; mitigate via #8, not via removal.*
- **Panel sizing — adjustable and persistent (the Round-3 question).** The main panel IS resizable today, via the custom `PanelResizeOverlay` (the styleMask is deliberately `[.borderless, .nonactivatingPanel]` — `.resizable` is excluded on purpose, comment explains the cursor/privacy interplay). Width 380–2400, collapsed height 110–240 (auto-follows the composer), expanded 280–1000; the frame persists (`AppSettings.panelFrame`, 0.2 s debounce) and restores at launch. No change needed or made. The Settings window is a fixed 620×520 SwiftUI scene — not user-resizable. *Severity: low* (settings are a reference surface, not a workspace); making it resizable is a one-line `.windowResizability` decision for YC, not implemented here.
- **Error tone — a strength.** Errors say what happened and what to do next, in the user's language, and are placed where the failed action lives (test-connection result under the button, capture notes behind the ⓘ chip with blocking ones tinted orange, storage-full tells the user records are *not* auto-deleted). No raw `NSError` strings reach the user except where appended after a human sentence.
- **Empty states — present everywhere checked:** chat (guided chips), conversation list (two distinct empties: none-yet vs no-search-match), transcript page, quick-command editor ("选择或新建一条指令"), Ollama model picker. No blank-white-page states found.
- **Small nits (recorded, not fixed — each needs a Mac eyeball):** (1) the response-mode toggle is icon-only in the composer; its meaning lives in a tooltip — first-time users get no label until they hover; (2) the header's turn/conversation counters (`3/200 · 2/50`) are cryptic without the tooltip; (3) `AppLanguage` offers system/en/zh-Hans only — after #9, a zh-Hant user can follow the *system* but cannot pin Traditional in-app (see new finding #31 in COVERAGE.md — small fix proposed, not landed: it adds a user-facing case and belongs with the native review of the #9 draft).

### C. Recording notes panel — implemented (`c6f11ce`)

- **What:** a small floating teleprompter window for demo recording. Plain text only, always on top (`.floating`), borderless non-activating panel; write-ahead persistence.
- **Files:** new `Wisp/UI/NotesPanel.swift` (controller + view); wiring in `AppDelegate.swift` (hotkey name + handler), `WispApp.swift` (菜单项）, `SettingsView.swift` (Recorder row, Panel tab), `AppSettings.swift` (`notesText`, `notesPanelFrame`; both join `wipeLocalData`), `Localizable.xcstrings` （录制笔记 / 录制笔记： keys; en translated, zh-Hant machine draft per #9 policy).
- **Entry points:** menu （唤起助手 below) and `KeyboardShortcuts.Name.toggleNotes` — unassigned by default, exactly like `pushToTalk`, assignable in Settings → Panel.
- **Resizable (explicit requirement):** drag any edge via the existing `PanelResizeOverlay` (same geometry code as the main panel); min 220×140; frame persisted with PanelController's 0.2 s-debounced `NSStringFromRect` pattern and restored on first show; default position top-right of the active screen, clear of the bottom-centre main panel.
- **Privacy choice (documented in the file header):** the window gets `ScreenPrivacy.apply(to:)` like every Wisp window. With 共享时隐藏 ON, notes stay on the presenter's own screen but are excluded from share/recording — the teleprompter case, and the reason this feature exists. With it OFF, notes are visible in the share like any other window. No separate toggle: one privacy switch with one meaning ("Wisp windows") beats a second per-window exception.
- **Deliberately absent:** rich text, multiple notes, sync, timestamps, any capture/conversation integration.
- **Unverified without a Mac:** compilation and all AppKit behaviour are **CI-pending**; code is pattern-faithful by inspection (panel construction mirrors PanelController/IslandController; sources are directory-globbed in project.yml, so no project change is needed). First CI run is the real check.

### D. Feature gaps — proposals only, ranked by fit with "lightweight, fast, simple"

1. **Localization-key lint in CI** — a script asserting every `String(localized:)` multiline literal exists verbatim in the catalog; kills regression pattern (a) at zero runtime cost.
2. **AGY path cache keyed on mtime** — removes the only avoidable per-request spawn (see A); tiny, testable seam.
3. **Shared URLSession for the cloud provider** (#30) — one-line-class change, removes a per-question TLS handshake from the hottest path.
4. **"Copy last answer" global hotkey** — the answer is the product; today it takes panel focus + hover + click. One `KeyboardShortcuts.Name`, unassigned by default, reuses `copyToPasteboard`.
5. **First-run onboarding** (#8 spec) — the only proposal that grows the UI, and the one with the largest adoption payoff per line.
6. **zh-Hant in-app language pin** (#31) — three lines once the #9 draft passes native review.
7. **Panel "pin" (disable idle-dismiss for this session)** — presenters already work around auto-hide; a per-session pin is one bool on the existing timer path. (The notes panel now covers most of this need — ranked last deliberately.)

---

## Linux harness

Built and run — full record in `tools/linux-harness/README.md` (committed `31f89d0`). Summary:

- **Toolchain:** Swift 6.2 (official tarball) at `~/swift-toolchain/swift-6.2`, Ubuntu 24.04 x86_64. (The parent's note said no toolchain existed when round 2 began; it was installed mid-round, which is what upgraded several "CI-pending" records above.)
- **Location:** `tools/linux-harness/` (lowercase — `Tools/` would collide with the existing `tools/` on case-insensitive APFS). SwiftPM, not in project.yml, git-ignores its synced source copies and `.build`.
- **Closure achieved:** the full 21-file Foundation-only starting set compiles (`swift build` clean): all of `Wisp/LLM`, `Capture/{BrowserTextExtractor, ChromeProfileInspector, ContextPacket, PageTextScript}`, `Store/{Conversation, ConversationStore}`, `Listening/{ListeningTranscript, ONNXModelInfo}`, `Support/AppSettings` — plus mechanically extracted pure functions (`ContextCapture.truncate` family, `ScreenCapturer` geometry) re-extracted verbatim on every sync. `LocalSpeechCatalog` was the one starting-set file that did not survive: its model/family types wrap sherpa-onnx builders (documented exclusion; #25's file is outside the closure for the same reason).
- **Shims:** harness-side only, in `HarnessShims.swift` — Combine stand-ins, `String(localized:)`, `URLSession.bytes(for:)`, in-memory Keychain, inert ScrollDriver, mirrored shortcut types + one catalog constant (sync-asserted), mirrored `UpdateChecker` accessors, plus ONE documented line-drop in the copied provider file (`waitsForConnectivity` is get-only-false on Linux). No app source edited. Every shim's fidelity limit is in the harness README.
- **Real run (`swift test`, 2026-11-02): 98 tests executed, 96 passed, 2 failed** (~21 s; 18 suites, 16 fully green). Ported: all round-2 fix tests + subsets of ClaudeCodeCLIProviderTests-collection, ResponseModeTests (12/21), CaptureScopeTests (5/5), NonAudioAcceptanceTests (4/9), ListeningTests (15/45). Trims are documented per file and in the README.
- **The 2 failures:** (1) `testOversizedPromptIsTruncated` — genuine locale-dependent failure, promoted to finding **#32** above; (2) `testExcludedAppsAreAlwaysHiddenFromWholeScreenCaptures` — platform artifact (`Bundle.main.bundleIdentifier` is nil under SwiftPM; the macOS suite runs app-hosted). Neither is an app-code regression.
- **Status upgrades earned:** #10, #11, #13, #27 → **Linux-verified** (+ macOS CI-pending); #14, #28 → derivation wiring Linux-verified against mirrored accessors. A platform note worth keeping: swift-corelibs-xctest's discovery traps on `@MainActor` test methods — the ported acceptance tests bridge around it (assertions byte-identical).

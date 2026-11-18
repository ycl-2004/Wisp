# Wisp Audit — Round 4: Adversarial Multi-Lane Round

- **Date:** 2026-11-02
- **Branch:** `fix/audit-2026-11-02` on base `1e86359` (v0.4.0). **Nothing pushed; the GitHub remote was never touched.**
- **Shape:** four parallel read-only attack lanes (lane 4 also wrote tests), then all fixes applied sequentially by one coordinator with the established TDD discipline (worst case → failing test first where a seam exists → minimal fix → honest verification status). Issue numbering continues from #33; full issue text in `AUDIT-FIXES.md` §(a2).
- **Headline:** **No High-severity finding, and no real injection / SSRF / key-leak path exists in this codebase.** The most severe item is #36 (Medium-High): an indefinite hang when a CLI's descendant holds the pipes. The security lane's held list is long and specific — read it as the round's main security result.

---

## 1. Lane verdicts

### Lane 1 — Security attack (4 findings, 8 attack lines HELD)

Attacker model: a malicious webpage the user merely has open; secondarily, hostile/broken endpoints and same-user processes.

Findings → #38 (uncapped `data(for:)` bodies), #39 (debug-dump defaults gate), #52 (no cumulative stream cap — proposal), #53 (temp-dir leftovers — proposal).

**Attacked, held:**

1. **AppleScript/JS injection via page content, selection, or URL — no path.** Script inputs are allowlist bundle IDs plus static script strings only; `appleScriptLiteral` escaping is complete; there is no `do shell script` anywhere; osascript receives code via stdin, never interpolated with page data.
2. **Prompt-injection escalation — mitigated as designed.** Page text reaches the model as evidence under explicit instructions; CLI providers run constrained (Claude `--restricted`/`--tools Read`, Codex read-only sandbox + Wisp throws on server-initiated requests, AGY `--sandbox`).
3. **SSRF / loopback smuggling — fails closed.** Loopback determination held against `127.1`, `2130706433`, `0x7f.0.0.1`, IPv4-mapped IPv6, trailing-dot and subdomain localhost, IDN lookalikes; userinfo/query/fragment smuggling is rejected at endpoint construction.
4. **Redirect credential leak — no path.** Every session honors `PrivateAPIRedirectPolicy` (redirects refused), so `Authorization` cannot follow a redirect to another host.
5. **Argument injection via model name / CLI path / config — no path.** The model travels as a separate argv value or a JSON-RPC parameter; the CLI binary is `Process.executableURL`, never a shell string.
6. **Temp-dir / storage races — no privilege gain.** UUID names, 0700 at creation, listening storage fails closed on symlinks.
7. **Update checker trust path — sound.** It never downloads or executes anything; the release payload is used only for a version comparison and an outbound link.
8. **Diagnostics exfiltration — airtight.** Gated behind `#if DEBUG && WISP_DIAGNOSTICS`, a flag defined nowhere in `project.yml`; there are zero `print`/`NSLog`/`os_log` calls in `Wisp/`.

Same-user note (accepted threat model, recorded with #39): a same-user process can also rewrite `baseURL` in defaults — for a non-sandboxed app that is inherent; #39 removes the *screenshot-oracle* asymmetry because the attacker lacks Wisp's Screen Recording grant.

### Lane 2 — Concurrency & error paths (10 findings, 6 groups HELD)

SWIFT_STRICT_CONCURRENCY is `minimal`, so this lane hunted what the compiler isn't checking. Findings → #37, #40, #41, #42, #43, #46, #47, and store items merged into #35.

**Attacked, held:**

1. **Stream lifecycle / generation guards** — cancelled or superseded streams cannot mutate a new conversation; cancel persists the partial answer *with* the 「回答未完成」 marker.
2. **Codex/AGY RunBox boundaries** — launch already inside the lock (the pattern #37 copied into Claude).
3. **Continuation bridges** — no missed-resume or deadlock found; no `DispatchQueue.main.sync` anywhere.
4. **Listening pipeline threading** — consistent.
5. **Singletons** — all @MainActor or UserDefaults-backed; `DrainBuffer` correctly NSLock-guarded.
6. **Remaining `try?` sweep** — mostly fail-visible; `ListeningModel.save()` is the positive example (write errors are returned and shown).

### Lane 3 — Extreme inputs (6 numbered findings + degraded notes)

Each input was traced through the code, not assumed. Findings → #34, #36, #44, #45, #49, #50, #51.

**Settled protections re-verified under variant pressure:** the #10 stream cap, #11 stderr cap, and #27 line cap all **hold** — overflows throw and reach the user as errors.

**Degraded-but-acceptable (not numbered):** directory at the store path (folded into #35); symlink at the store path is replaced rather than followed; a configured non-executable CLI path silently falls through to a detected install; hung servers misdiagnosed as "not running" in probe/generation timeout mapping; stream timeout message cites 60 s after a 300 s resource-timeout wait (message accuracy nit); silent dead-microphone recording (no input-liveness watchdog); advanced hotkeys die silently when Accessibility is revoked (scroll collection, by contrast, degrades explicitly). These are recorded here as known polish gaps, not fixed — most are message-accuracy or diagnostics niceties disproportionate to a fix each.

### Lane 4 — Test engineering (baseline verified, 69 tests added)

- Baseline before changes: **98 executed / 96 passed / 2 failed** (the same #32 + bundle-ID artifact).
- Gap audit: SSEParser had no direct tests; `ContextCapture.truncate` untested directly; ONNXModelInfo untestable in its sherpa-bound home (extraction seam documented); CLIPrompt estimator/fit nearly untested; ConversationStore's contract much wider than its 4 acceptance tests; the three capped buffers lacked boundary/chunking matrices.
- Weak assertions found and fixed: W1 a "exactly at cap" test that actually built cap−8 (renamed; the true exact-cap case now lives in the fuzz suite, commit `c63d75e`); W2 the #32 test asserted only the bound, hiding its own root cause (now characterized precisely); W3 an ASCII-only cap assertion that couldn't distinguish byte vs char caps; W4 a corruption test that never asserted backup bytes (fixed by #33's work).
- New suites (harness + WispTests mirrors): `FuzzSupport` (SplitMix64 seeded PRNG), `SSEFuzzTests` (19), `TruncationCharacterizationTests` (16), `DrainBufferBoundaryTests` (7), `CLIJSONLinesFuzzTests` (7), `ONNXFuzzTests` (8), `ConversationStoreMatrixTests` (12). No fuzz case crashed or hung.
- Lane 4 also discovered #33 (same-second backup collision) while writing the corruption matrix.

---

## 2. Round-4 fixes (18 commits)

| Hash | Fix | Verification |
|---|---|---|
| `c63d75e` | Lane-4 fuzz/characterization suites (+69 tests), W1 rename | Linux-run |
| `abc5d96` | #33 backup-collision retry + block-on-failure | Linux |
| `0c7cb14` | #34 undecodable version blocks, never loads as v1 | Linux |
| `74b792f` | #35 store read/write failure surfaces (`saveIssue`, `.unreadable`) | Linux (banner CI-pending) |
| `18948a3` | #44 settings ceilings at the getter | Linux |
| `c0dd4cc` | #45 eviction skips the streaming conversation | Linux |
| `2fdcdcd` | #49 duplicate-ID dedupe on load, first wins | Linux |
| `cafe2e4` | #51 lossy SSE line decode | Linux |
| `51abc3f` | #50 Ollama probe wrong-shape → `.failed` | Linux |
| `993e939` | #48 QuickCommandStore corrupt-blob guard | CI-pending (tests WispTests-only) |
| `147e199` | #37 Claude RunBox launch inside the lock | CI-pending (mirrors in-repo pattern ×2) |
| `5c470b2` | #47 runAppleScript synchronized sink + honored wait | Linux (sink); osascript path CI-pending |
| `86651a9` | #36 poll-sliced CLI reads + snapshot returns | Linux incl. live fork-hold reproduction |
| `ee02135` | #38 capped small-body reads; #46 shared URLSession (also completes #10, implements #30) | Linux (cap mechanics + synthetic-protocol suites) |
| `5ebd5c1` | #39 debug-dump arm file | Linux |
| `b74b743` | #43 Keychain result checks + migration safety | CI-pending (Keychain/SwiftUI) |
| `64f6fbb` | #40/#41/#42 capture generations + applyHeader guard | CI-pending (AppKit) |
| `ce5a0ce` | #51 scope correction (errorMessage keeps its tested strict decode) | Linux (full suite) |

Proposals not implemented: **#52** (cumulative stream cap — product decision) and **#53** (startup sweep of orphaned `Wisp-*` temp dirs).

Catalog: +10 keys across the round (769 → 779), each en `translated`, zh-Hant `needs_review` machine drafts per the #9 policy — they join the native-review queue, they are not finished localization.

## 3. Test tallies (exact)

- Round start (post lane-4 baseline): 98 executed, 96 passed, 2 failed.
- After lane 4: 167 executed, 165 passed, 2 failed.
- **Final: 194 executed, 192 passed, 2 failed** — the same two known failures, nothing else:
  1. `CLIPromptFitCharacterizationTests.testOversizedPromptIsTruncated` — finding **#32**: `CLIPrompt.fit` doesn't account for its truncation marker's token cost (~93 EN / ~107 ZH by the app's estimator; harness result estimates 3,106 vs the 3,100 budget). Characterized and pinned by lane 4; **behavior unchanged — the fix direction is YC's product decision.**
  2. `CaptureScopeTests.testExcludedAppsAreAlwaysHiddenFromWholeScreenCaptures` — SwiftPM platform artifact: `Bundle.main.bundleIdentifier` is nil under the Linux harness. Not an app defect.
- WispTests mirrors of the CI-pending suites (#48, plus all harness suites) are **not compile-verified** (no macOS toolchain here); a few mirror assertions use Chinese marker/error strings and are locale-sensitive on an English-locale macOS host. The #32 characterization test is locale-sensitive by design.

## 4. Platform caveats discovered this round (harness honesty)

- swift-corelibs `Process`: `isRunning` latches (an exited child can report running until reaped), signals to children are unreliable, and `FileHandle.readabilityHandler` starves. Consequences: #36's CLICommand uses blocking-read threads into a snapshot box (verified on both platforms' semantics), and the fork-hold test asserts strict `timedOut`/`status` only on macOS (`#if os(macOS)`), with the reason recorded in the test. None of this affects Darwin behavior; it limits what the Linux harness can prove about process control.
- AppKit/SwiftUI/Keychain/KeyboardShortcuts surfaces have no Linux seam; those commits are marked CI-pending individually.

---

## 5. Git Integration Guide — how to land these 37 commits

### 5.1 How the branch is organized

37 commits over base `1e86359`, in four strata:

1. **Rounds 1–3 (19 commits, `980cdc2`…`31f89d0`)** — small verified fixes, round-2 caps/timeouts, zh-Hant draft, notes-panel feature, harness scaffold. One issue per commit.
2. **Lane-4 tests (`c63d75e`)** — tests only; safe anywhere in the stack.
3. **Round-4 fixes (17 commits, `abc5d96`…`ce5a0ce`)** — one issue per commit (three commits deliberately pair inseparable items: #38+#46, #40+#41+#42, and the #51 scope correction `ce5a0ce` which amends `cafe2e4`). Every commit message states the finding, the fix, and its verification status (Linux-verified vs CI-pending) — the history is self-documenting and bisectable.
4. **Uncommitted audit docs** — `CODE-REVIEW-2026-11-02.md`, `AUDIT-FIXES.md`, `AUDIT-ROUND2.md`, `AUDIT-ROUND4.md`, `COVERAGE.md` live in the clone root only. Decide separately whether they belong in the repo at all (they reference local paths and process detail; the recommendation is to keep them out of the public repo, or add only a condensed summary).

The branch is linear (no merges), every commit compiles-or-is-docs by construction, and test commits interleave with the fixes they verify.

### 5.2 Exact landing steps

1. **Finish the GitHub App installation** (the current blocker): on the install page choose **Only select repositories → Wisp**. OAuth alone does not grant repo access; nothing can be pushed or CI-checked until repo selection is verified.
2. **Push the branch:** `git push -u origin fix/audit-2026-11-02` from `~/workspace/wisp-review`. (First push also creates the remote branch; no force flags needed — `main` is untouched and the branch is a fast-forward descendant of it.)
3. **Open a PR against `main`**, titled e.g. "Deep audit rounds 1–4: 53 findings, caps/races/data-loss fixes, fuzz suites". Link `AUDIT-ROUND4.md`'s verdicts in the description (or paste §1–§3 if the docs stay out of the repo).
4. **Let CI run both jobs** — the existing `macos-15` job and the round-2 `macos-14` job (`3d5af10`). CI runs `xcodegen generate` first: the project file is generated, never committed, so the new files (notes panel, all Round4 test files, lproj folders) are picked up automatically — **no manual project regeneration is needed or wanted.**
5. **Review the CI result before merging.** The first macOS compile of several items happens here: the notes panel (`c6f11ce`), the AppKit capture-generation changes (#40–42), Keychain/Settings changes (#43, #48), the RunBox change (#37), and every WispTests mirror suite. Treat a red first run as expected triage, not alarm — fix forward on the same branch.
6. **Merge strategy — recommendation: squash-merge is wrong here; use a merge commit (or rebase-merge).** Reasoning: the 37-commit history is the audit's evidence trail — one issue per commit with verification status in each message. Squashing destroys the per-issue mapping (and the red→green test commits) that makes the audit auditable. A merge commit preserves it while keeping `main`'s first-parent history clean; rebase-merge is equally acceptable if a linear history is preferred. Do **not** cherry-pick selectively: later fixes assume earlier ones (e.g. #35 builds on #33/#34's LoadIssue cases; #36's comments cross-reference #47's sink).
7. **After merge:** tag or release as usual; remember the release flow still builds ad-hoc (issue #7 — notarization is a separate, still-open decision requiring the paid Developer Program).

### 5.3 What can go wrong at each step

| Step | Risk | Mitigation |
|---|---|---|
| 1. App install | Selecting "All repositories" grants broader access than intended | Choose "Only select repositories → Wisp"; verify via the connector's repo read before pushing |
| 2. Push | Wrong remote/branch (the clone's remote was off-limits all audit) | `git remote -v` + `git status` before pushing; push only the named branch |
| 4. CI (first macOS build) | Compile errors in CI-pending items; locale-sensitive mirror assertions failing on an English-locale runner; the `macos-14` job surfacing minimum-OS issues the 15 job hides | Fix forward on the branch; expect 1–2 red iterations. Locale-sensitive tests are named and documented (§3) |
| 4. CI (tests) | The #32 characterization test is *expected* to document current behavior; on macOS it may pass or fail depending on host locale (that's the finding) | Don't "fix" it by editing the test — #32's direction is a product decision |
| 6. Merge | Conflicts if `main` moved since `1e86359` (it hasn't during the audit, but check) | Rebase the branch onto current `main` locally, re-run the Linux harness (194/192/2 baseline), then update the PR |
| Post-merge | Users on the zh-Hant draft (#9) see machine-converted strings | The draft is behind normal locale selection and marked `needs_review`; native review before any release announcement is the standing recommendation |

### 5.4 What remains manual (not in any commit)

- **Notarization / Developer ID signing (#7)** — needs YC's paid Apple Developer account and an identity decision.
- **zh-Hant native review (#9)** — all 767 original keys + 10 round-4 keys are machine drafts (`needs_review`); also the in-app language pin lacks a zh-Hant case (#31).
- **#32 fix direction** — reserve marker tokens in `CLIPrompt.fit` (costs prompt space) or exclude the marker from the budget (accept the overshoot). Product call.
- **#5 wipe behavior** — factory-reset-or-not is a product call (comment corrected; behavior unchanged).
- **#8 onboarding** — designed in `AUDIT-ROUND2.md`, not implemented.
- **#52 / #53** — proposals above.
- **`.fable/` tracked agent work-notes (#24)** — transparency-vs-hygiene call; untouched per instructions.
- **Settings window resizable** — one-line fix identified in round 3; YC's call.
- **GitHub topics (#26)** — one-line web-UI follow-up; the remote stayed off-limits.

# Wisp Deep Audit — Round 5 (approved final batch) + Round 6 (end-to-end proof)

Continues `AUDIT-FIXES.md` / `AUDIT-ROUND2.md` / `AUDIT-ROUND4.md`. Same branch
`fix/audit-2026-11-02`, same discipline (worst case → failing test first where a
seam exists → minimal fix → verify in the Linux harness; macOS-only changes are
marked CI-pending and never claimed as compiled). Round 5 items were approved
by YC after rounds 1–4 closed; round 6 is verification-only scope YC added
afterwards (integration proof on this server — no new audit surface).

**Branch state after round 5: 42 commits over base `1e86359`** (37 after round 4,
+5 this round). Harness after round 5, full run measured: **204 executed, 202
passed, 2 failed** — round 4's #32 known failure is FIXED (below); the two
failures are the SwiftPM `Bundle.main.bundleIdentifier` platform artifact
(CaptureScopeTests, present since the harness was built) and one flaky
timing assertion in Round4PipeDeadlineTests (details in the tally section).
Settings-resizable is CI-pending and not counted here. Final tally after
round 6: see the Round 6 section at the bottom.

---

## Round 5

### #32 — CLIPrompt.fit now reserves the truncation marker's cost — FIXED `4120e4f`

- Direction (YC's call): when `fit` truncates a section it must charge the
  omission marker `ContextCapture.truncate` will insert, so content + marker
  never exceeds the budget in EITHER estimation locale. (The estimator prices
  CJK characters differently per locale, and the marker — which contains the
  section's own start/end labels in the content's script — costs ~93 estimated
  tokens in the EN path vs ~107 in the ZH path. That asymmetry is exactly why
  the old test passed on EN hosts and failed on ZH hosts.)
- Test first: the existing harness characterization test documented the breach
  (fit to a 3,000 budget could yield ~3,107 estimated tokens on the ZH path).
  It was rewritten as two invariant tests over both estimation paths, and
  WispTests' `testOversizedPromptIsTruncated` was tightened to the real
  budget (its old ≤3,100 fudge existed precisely because of this bug).
- Fix: `ContextCapture.omissionMarker(omitted:previousEnd:nextStart:)` is now
  the single source of truth for the marker text (`truncate` calls it too), and
  `CLIPrompt.truncationMarkerReserve(for:)` prices a worst-case marker per cut
  (32 CJK characters per sample slot — the most the estimator can charge —
  with the omitted-count given the section count's full digit width). `fit`
  subtracts budget-overrun + reserve at each cut.
- Deliberately untouched: the 2,000-character allowance floor in `fit` (a
  small section is kept whole even over a tiny budget — an existing product
  behaviour, not this bug; both test suites now document it explicitly).
- Verified: harness CLIPrompt/ContextCapture suites 19/19, including the ZH
  estimation path that failed before. The EN path asserts the same invariant
  in WispTests (macOS CI).

### #52 — Cumulative stream cap for cloud responses — IMPLEMENTED `25f04ec`

- Round 4 proposed this: #10 capped a single SSE line (1 MiB) and error
  bodies (64 KiB), but a stream of endless *legal* lines had no total bound.
- Design: `StreamByteBudget` (in `SSEParser.swift`) — `maxTotalBytes =
  32 MiB` of raw stream bytes. Rationale (also in the code comment): a
  legitimate deep answer is ~1 MiB of text; SSE framing multiplies bytes a
  few times over at most, so 32 MiB sits an order of magnitude above any real
  answer while still bounding worst-case memory/time; the 300 s resource
  timeout already bounds duration, this bounds volume. Counted per raw byte
  *before* parsing, in the 2xx streaming loop only (the error-body path is
  already capped separately). Overflow throws inside the loop and maps to
  `ProviderError.network("服务端返回的数据总量过大，已中断。")` — the same shape
  as the #10 line-cap error beside it.
- Tests first (red confirmed): 5 unit tests for the budget (under / exactly
  at / over / clamping at the limit when it throws / 32 MiB constant) in both
  WispTests and the harness port; harness stream-guard suites 18/18. The
  end-to-end proof (a 36 MB no-[DONE] stream terminated by the cap, not by
  the end of the body) is round 6's `Round6FakeCloudTests`.
- Catalog: the new message key was added — and so was its #10 sibling
  ("服务端返回的单行数据过长，已中断。"), which the audit found was **missing
  from the catalog entirely** (every locale had been falling back to the
  Chinese source string). Both inserted with en translations and zh-Hant
  draft translations flagged `needs_review` (same human gate as #9; flags
  not lifted). Catalog 779 → 781 keys, JSON re-validated.

### #5 — "删除全部数据" is now a true factory reset — FIXED `c6dc30f`

- Change: `AppSettings.K` gained `K.all`, an explicit enumeration of all 41
  persisted keys (with a comment that new keys must be added or the wipe —
  and its test — will miss them). `wipeLocalData()` still removes the
  support directory, and now removes every `K.all` key from UserDefaults.
- Absent-vs-empty analysis (the round-1 blocker), done reader-by-reader:
  - Keys registered in `init` via `register(defaults:)` live in the volatile
    registration domain — never persisted — so a removed registered key
    reads back exactly its first-launch value.
  - Every unregistered-key reader nil-coalesces to the same fallback a
    fresh install sees (verified by grep over AppSettings readers).
  - The one presence-based reader, `adoptLegacyCloudConfig()` (checks
    `d.object(forKey:)` for nil), runs only when a legacy Keychain entry
    exists; the wipe's caller deletes the Keychain *before* calling
    `wipeLocalData()`, so post-wipe it is unreachable — identical to a
    fresh install.
  - Explicitly out of scope (not AppSettings keys, unchanged by design):
    KeyboardShortcuts library bindings, the `AppleLanguages` pin,
    `localSpeechScanRequested`, and the Settings tab selection.
- UI copy now matches the behavior exactly (the old copy understated it):
  button 「删除全部数据与设置」, section note and alert rewritten to say
  conversations, recordings, transcripts, debug files, API keys are deleted
  AND all settings return to defaults. Catalog +3 keys → 784 keys, zh-Hant
  drafts flagged `needs_review`.
- Tests first (red confirmed: 34 of 41 sentinel keys survived the old wipe):
  `Round5WipeTests` / harness `AppSettingsWipeTests` — 4 tests using an
  *independent* enumeration of all 41 key names as literals (so a key added
  to `K` but not to `K.all` fails the test), first-launch values after wipe
  (registered and unregistered), non-AppSettings keys untouched, support
  directory removal. Harness 4/4.

### Settings window resizable — DONE `e510ef0`, CI-pending

- The audit found the Settings scene fixed at 620×520 (the root view's
  `.frame(width:height:)`), so long provider lists and the data section
  forced scrolling in a window the user could not enlarge.
- Smallest faithful change: the Settings scene in `WispApp.swift` gains
  `.windowResizability(.contentMinSize)` (the pattern the main panel
  already relies on), and the root frame becomes
  `.frame(minWidth: 620, minHeight: 520)` — same default size, now a floor.
  SwiftUI/AppKit only: not compilable on this server, marked CI-pending;
  the pattern is copied from the app's own scenes, no new API surface.

### #24 — `.fable/` untracked — DONE `d355763`

- `git rm -r --cached .fable` + `.fable/` added to `.gitignore`. The two
  files (722 lines) remain on disk byte-for-byte (md5 verified before and
  after); only tracking stops. History is untouched — this does not rewrite
  the past, it stops the notes growing the public repo from here.

### Round-5 harness tally

Full-suite run after the batch: **204 executed, 202 passed, 2 failed** — the
2 failures are pre-existing and neither is in round-5 code: (1) the SwiftPM
`Bundle.main.bundleIdentifier` artifact in CaptureScopeTests (present since
the harness was built), (2) a timing assertion in Round4PipeDeadlineTests
(`testRunReturnsWhatArrivedDespitePipeHoldingGrandchild`, the CLICommand
timeout-path bound under full-suite load). The flake characterization was
verified afterwards: the suite passes 4/4 in isolation, and the test passed
again in both round-6 final full runs. Round 4's #32 known failure is gone —
fixed, not reclassified.

---

## Round 6 — end-to-end proof on this server (Part A: local doubles)

All scaffolding lives in `tools/linux-harness` only; app sources changed
nowhere in Part A. Three new suites, **25 tests**:

### Round6FakeCloudTests (8) — real provider vs scripted in-process endpoint

`OpenAICompatibleProvider` driven through a URLProtocol stub (the harness's
established seam): request construction asserted from the captured body
(model / `stream: true` / messages); normal SSE assembles deltas in order
and stops at [DONE] (a post-[DONE] delta is never delivered); unparseable
lines are skipped while an in-stream `{"error": …}` object surfaces —
**by design** — as a visible `"\n\n[服务端错误] …"` note inside the answer
(asserted as the intended behaviour, not a bug); non-2xx JSON maps the
server's message (400 → `.http(400, …)`); an error body over the cap is
still mapped from its first 64 KiB (400 keeps its head message, 401 →
`.unauthorized`); a single SSE line over 1 MiB trips the #10 error; a
~36 MB stream of legal lines with no [DONE] is terminated by the #52 cap
with the total-too-large network error and assembly stopping at the cap;
an abrupt transport failure throws instead of hanging or faking success.
Soak: 200 sequential requests, all correct, **0.10 s** total (smoke-level
stability only — not a leak profile).

Fidelity limits, measured not assumed: swift-corelibs' URLProtocol
delivers only the *last* `didLoad` chunk (verified directly: chunks of
7+15+4 bytes arrived as 4), so stub bodies are sent as a single load —
byte-split invariance is covered separately by SSEFuzzTests at the
pipeline level. And the harness's whole-response `bytes(for:)` shim means
bytes arrive buffered: time-to-first-token and partial-delivery-before-
disconnect cannot be reproduced here (macOS-only by construction).

### Round6RealServerTests (6) — real provider + Ollama probe over real TCP

A throwaway Python HTTP server on 127.0.0.1 (the provider's loopback
exception is the designed seam): cloud SSE streamed over a real socket
assembles in order; a real-socket 400 maps its JSON message; the Ollama
probe reads scripted `/v1/models` shapes — good shape → `.running` with
sorted IDs; `data: []` → `.running([])` (a real zero-model answer); the
wrong (native `/api/tags`-style) shape → `.failed`, the #50 regression;
connection refused → `.notRunning`.

### Round6CLIProviderTests (11) — executable fakes through the real providers

Python executables emitting each tool's real wire format, found via the
configured cliPath exactly like a user install:
- **Claude** (stream-json): success assembles; crash after a partial delta
  throws `.claudeCodeFailed(status 3)` with the stderr tail (the streamed
  partial is *not* reported as success); a 1.5 MiB stderr flood completes
  (concurrent DrainBuffer drain); the #36 repro — fake answers, forks a
  12 s grandchild holding both pipes, exits 0 — completes well inside the
  hold; missing binary → `.claudeCodeNotFound`.
- **Codex** (app-server JSON-RPC): the full initialize → model/list →
  thread/start → turn/start handshake against a stateful fake completes
  with the assembled answer; a mid-turn crash → `.codexFailed`; missing
  binary → `.codexNotFound`.
- **AGY** (stream-json): step_update deltas + SUCCESS result assemble;
  a FAILURE result → `.agyFailed` with its detail; missing binary →
  `.agyNotFound`.

No real bug was exposed by Part A — no app-source change, no new issue
number was needed.

## Round 6 — Part B: a real local model in the loop

**Setup.** Ollama **0.40.13** from the official Linux distribution
(`ollama.com/download/ollama-linux-amd64.tar.zst`, 1,525,346,571 bytes),
extracted to `~/ollama` and run as a plain user process (`ollama serve`,
no systemd). Two environment notes for reproducibility: the first
download attempt was silently truncated at 61% by a dropped background
session and was completed with `curl -C -` resume (the extractor caught
the truncation — the tar stream ended mid-member); and the VM has
libzstd.so.1 but no zstd CLI, so extraction used a ctypes shim over the
system library. Model: **qwen2.5:0.5b** (Q4_K_M) — chosen for this
CPU-only, shared 4-core VM: 397 MB per `ollama list`, 380 MB on disk
under `~/.ollama/models`. llama3.2:1b (~1.3 GB) was the alternative and
lost on size/RAM headroom.

**Measurements** (fixed prompt "Explain in two sentences why the sky is
blue.", native `/api/generate` counters for speed, streamed `/v1` for
TTFT; reported as measured, no spin — this is a small model on shared
CPU):
- Cold first request: **5.74 s total**, of which the server reported
  load_duration **2.40 s** (model load), prompt_eval 0.61 s, eval 2.61 s.
- Warm time-to-first-token: **median 0.10 s** (range 0.09–0.10, 3 runs).
- Generation speed: **median 16.1 tok/s** (range 15.2–17.6, 3 runs).

**E2E through the app's compiled code** (`Round6RealOllamaTests`,
env-gated by `OLLAMA_E2E` so the default suite stays hermetic; run with
the gate on: **3/3 passed**):
- `OllamaSupport.probe` against the real server → `.running` listing
  qwen2.5:0.5b. (Note: the app has no `/api/chat` client — its native
  Ollama surface is this `/v1/models` probe plus OpenAI-compatible chat,
  so that is what "native path" means here.)
- `OpenAICompatibleProvider` at base URL `http://127.0.0.1:11434/v1`
  with a placeholder key (Ollama ignores it) streamed a real answer
  end-to-end — "pong"/"Pong!" across runs — with **no SSE dialect
  mismatch**: Ollama's chunk format, final-chunk shape, and [DONE] all
  parse exactly like the fake-cloud scripts.
- `validate()` against the text-only model returned
  `.imageUnsupported` carrying Ollama's own message ("Multimodal data
  provided, but model does not support multimodal requests.") — that is
  validate's designed outcome for a non-vision model (it sends a test
  image on purpose), and it proves the real server's 400 error dialect
  lands in the mapper's image-hint path. First recorded as a test
  failure, then recognized as the contract and asserted as such.

**NVIDIA NIM leg — auth/catalog only, by account state.** Verified
firsthand via the connector helper: `GET /v1/models` with the
vault-provided NVIDIA key returns the catalog (**85 models** — the key
authenticates); `POST /v1/chat/completions` returns **HTTP 404
"Function … Not found for account …"** for every model tried
(mistral-7b-instruct-v0.3 confirmed in this round; the same result was
reported for deepseek-coder-6.7b, llama-3.2-11b-vision, gemma-2b). The
account has no entitled generation function yet — a build.nvidia.com
entitlement state, not a code or key problem. The generation E2E is
therefore recorded as **ready-but-unrun**: when entitlement appears it
re-runs in minutes through the same cloud provider (the helper also
supports `--stream` raw SSE capture for dialect samples). The key value
appears nowhere in code, commits, docs, or this record.

### Final full run and what remains macOS-only

Final harness run (plain `swift test`, no env gates; two consecutive
runs identical): **232 executed, 228 passed, 3 skipped, 1 failure** in
~63 s.
- The 1 failure: `CaptureScopeTests.testExcludedAppsAreAlwaysHiddenFromWholeScreenCaptures`
  — the SwiftPM `Bundle.main.bundleIdentifier` artifact, pre-existing
  since the harness was built, untouched by rounds 5–6.
- The 3 skips: the env-gated `Round6RealOllamaTests` (3/3 passed in the
  gated run above).
- Arithmetic check: round-5 tally 204 + round-6's 28 = 232. ✓

Proven end-to-end on this server: cloud streaming (assembly, [DONE],
error mapping, both caps, disconnect), the Ollama probe's four shapes,
all three CLI providers' full wire protocols incl. crash/flood/
grandchild/missing-binary behaviour, a 200-request soak, and a real
model answering through the app's own provider code on both the probe
and chat paths.

What remains macOS-only, by construction: everything AppKit/SwiftUI
(the round-5 Settings-resizable change compiles first in macOS CI);
incremental-delivery timing (TTFT and partial deltas before a
disconnect — the Linux harness reads through a whole-response shim);
the CLI providers' behaviour against the *real* claude/codex/agy
binaries and their auth states; and the WispTests counterparts of the
round-5 tests (same assertions, macOS CI). The landing guide in
`AUDIT-ROUND4.md` is unchanged: push → PR → CI (macos-15 + macos-14) →
merge commit or rebase, not squash.


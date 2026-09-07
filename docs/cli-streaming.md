# CLI answer streaming

Wisp's chat view already appends provider chunks as they arrive. The CLI adapters
now deliver those chunks before the model finishes instead of waiting for a
complete response. These changes do not reduce model startup or reasoning time.

## Codex

Wisp starts its own `codex app-server --listen stdio://` process in a private
temporary directory. The handshake is `initialize` → `initialized` → `model/list` →
`thread/start` → `turn/start`, waiting for each request's response. The thread
uses `ephemeral: true`, `sandbox: read-only`, and `approvalPolicy: never`;
the configured model is preserved. Screenshot paths use `localImage` input.

Only `item/agentMessage/delta` supplies incremental answer text. Final
`agentMessage` items fill missing suffixes without repeating already displayed
text. Reasoning, tool events, legacy duplicate notifications and events for
other threads are ignored. Success requires `turn/completed` with a completed
status and nonempty answer text. RPC errors, failed turns and unexpected
server requests fail the stream, apart from the bounded Fast fallback below;
Wisp does not auto-approve server requests.

The app-server is long-lived by design, so Wisp terminates its own process at
the end of each request, with a forced-stop fallback. It never connects to or
stops an existing Codex daemon. The 240-second timeout remains in effect.
There is no fallback to `exec`: unsupported app-server versions return an error.

Protocol source: [OpenAI App Server documentation](https://developers.openai.com/codex/app-server).
The request shapes were also checked against JSON schemas generated locally by
`codex app-server generate-json-schema` from version 0.153.4.

## Antigravity (AGY)

This integration runs `agy`, not Google's `gemini` CLI. It retains the existing
prompt budget, `--sandbox`, screenshot paths and 300-second timeout, changing
the output mode to `--output-format stream-json`.

AGY 1.1.27 emits `event: step_update` with a nested `step_update`; only
`step_type: agent_response` and its `text_delta` enter the answer. A `DONE`
step can still carry the last delta. A successful `event: result` plus a zero
process exit code is required. The final response is used as a fallback when
no deltas arrived, or supplies a missing suffix when it extends the stream.
It is not appended a second time. A final response can omit earlier agent
steps, so it is not used to overwrite already streamed intermediate messages.

## Fast defaults and fallback

- **Codex:** read `model/list` (including paginated results) and request the
  selected model's tier named `Fast`. The local CLI advertises `priority` as
  its ID, including for gpt-5.6-luna. Models without that capability explicitly
  use `default`. A Fast/tier rejection before text delivery retries once on a
  fresh ephemeral thread with `serviceTier: default`. Failures after text has
  arrived remain errors to avoid replaying a partial answer or repeating work.
- **Claude Code:** supported explicit Opus selections use
  `--settings '{"fastMode":true}'`, which also works with `--restricted`.
  The current official list includes Opus 5 and Opus 4.8; the `opus` alias
  follows the CLI's current Opus. Sonnet, Haiku, older/unknown model IDs and an
  unspecified CLI-default model retain normal behavior. This prevents Fast
  from silently switching an unsupported model to Opus. No global settings
  are edited. Native Claude availability/credit/rate-limit fallback remains
  in control; administrative restrictions are not overridden.
- **AGY:** the general reference still lists the old `/fast` command, but the
  more specific execution-mode page says it was removed in 1.1.0. Local
  1.1.27 help has no Fast flag. Wisp therefore uses normal mode; neither
  `--effort low` nor permission-changing `--mode accept-edits` substitutes for Fast.

Fast can increase credit consumption or billing. It is independent of
streaming and does not alter Wisp's model selection or reasoning effort.
Sources: [Codex speed](https://developers.openai.com/codex/speed),
[Claude Fast mode](https://code.claude.com/docs/en/fast-mode),
[Claude CLI settings](https://code.claude.com/docs/en/cli-reference),
[AGY execution modes](https://www.antigravity.google/docs/cli/modes/).

## Validation — 2026-09-07

Live protocol probes used synthetic requests for eight sentences about clouds,
without screenshots or file/tool requests:

| CLI | Observed first text | Observed completion | Evidence |
| --- | --- | --- | --- |
| Codex 0.153.4 / gpt-5.6-luna | 3.930 s | 5.129 s | Multiple `item/agentMessage/delta` events; ephemeral thread confirmed |
| AGY 1.1.27 / gemini-3.8-flash-low | 3.101 s | 3.502 s | Three text deltas at 3.101, 3.301, 3.502 s, then `result` |

These timings establish incremental delivery in those runs, not a latency
guarantee. Claude CLI was not invoked. Regression tests exercise the production
providers with synthetic subprocesses as well as pure protocol fixtures.
The installed application and real screenshot requests have not been exercised
as part of these text-only probes.

Additional local Codex handshake checks confirmed that gpt-5.6-luna accepts
both `serviceTier: priority` and `serviceTier: default`, echoing the requested
tier and retaining the model and ephemeral flag. Those checks did not generate
answers. Claude Fast behavior is verified by official documentation and command
construction tests, not by invoking the local Claude CLI.

The full Debug XCTest run passed 32 tests with zero failures or skips, including
real synthetic subprocess checks for early delivery, EOF failure and cancellation
of a process that ignores SIGTERM. Machine-readable evidence is in
[cli-streaming-20260907.json](evidence/cli-streaming-20260907.json).
Release also builds successfully with `CODE_SIGNING_ALLOWED=NO`.

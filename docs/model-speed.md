# Model speed preferences

Wisp prefers accelerated service where the configured API documents support. This is a request preference, not confirmation that a response actually ran on a fast tier. Model choice and reasoning effort are preserved.

| Connection | Request behavior |
| --- | --- |
| OpenRouter paid models | `service_tier: priority`, throughput-first routing, provider fallback enabled |
| OpenRouter `:free` models | Throughput-first routing, original free model ID preserved; no paid tier requested |
| OpenAI official Chat Completions | `service_tier: priority` (equivalent to Fast on supported models) |
| Gemini official OpenAI-compatible endpoint | `service_tier: priority`; availability depends on model/account |
| Codex CLI | Existing model-list capability check selects advertised Fast tier, with existing standard-tier fallback |
| Claude Code | Existing Fast setting only for supported Opus 5 / 4.8 selections; no model switching to enable Fast |
| Anthropic compatibility API, Zhipu, Ollama, custom gateways, AGY | No unverified acceleration parameter injected |

OpenRouter may serve a standard endpoint when priority is unavailable. Direct APIs can reject unavailable tiers; Wisp surfaces API errors and does not claim that Fast was used. Speed and actual billing remain service-side decisions. Fast can cost more; provider help explains this. Preset price notes describe standard pricing, not Fast pricing. No paid request was made to verify account eligibility or benchmark latency.

OpenRouter presets: GPT-5.6 Luna, GLM-5.3 Flash, Qwen3.7 Flash, MiniMax M3 (free), Inkling (free fallback), followed by Custom. Existing saved model choices remain saved; Luna becomes the first/default preset for a fresh selection.

Sources checked 2026-09-07:

- [OpenRouter tiers and fallback](https://openrouter.ai/docs/guides/features/service-tiers)
- [OpenRouter provider sorting](https://openrouter.ai/docs/guides/routing/provider-selection)
- [OpenAI Fast mode](https://developers.openai.com/api/docs/guides/fast-mode)
- [Gemini compatibility and priority](https://ai.google.dev/gemini-api/docs/openai#flex-and-priority-inference)
- [Claude Code supported Fast models](https://code.claude.com/docs/en/fast-mode)

Validation: full XCTest passed 35 tests, zero failures, including preset order, free-ID preservation, direct-API parameters, unrelated-host isolation, and existing Codex/Claude argument checks. Tests use synthetic fixtures, not installed model CLIs. Result bundle: `/private/tmp/wisp-fast-models-tests.xcresult`.

# First-run onboarding — design (issue #8, v2)

Branch: `feat/first-run-onboarding`. Builds on the round-2 spec in
`AUDIT-ROUND2.md` (#8); this document records the final design as built,
including where it deliberately goes beyond or simplifies that spec.

## Problem

A fresh install cannot answer anything until the user discovers Settings
and configures a provider + API key (or installs a CLI / starts Ollama).
The first question ends in a bare configuration error. Onboarding turns
that dead end into a guided path to the first answer.

## Entry condition — derived, never stored

No `hasOnboarded` flag (nothing to drift out of sync). The pure function
`OnboardingReadiness.needsSetup(signals)` (in
`Wisp/Support/OnboardingReadiness.swift`, Foundation-only, unit-tested)
decides from live state:

- cloud ready: a Keychain key exists for the selected cloud provider
  **and** the effective base URL is non-empty;
- ollama ready: `OllamaSupport.probe` reports `.running`;
- CLI ready: any of Claude Code / Codex / AGY is detected on this Mac.

`needsSetup = !(cloud || ollama || cli)`. `AssistantModel` gathers the
signals (`refreshOnboardingReadiness()`), Ollama's probe being the only
async input.

## Triggers and the annoyance budget

- **Panel show** (`PanelController.show` → `AssistantModel.panelDidShow`):
  evaluate; offer the sheet at most once per launch, and never again
  after the user skipped it this launch.
- **Asking while unconfigured** (`send`): if `needsSetup`, present the
  sheet instead of firing the provider call that would fail with the
  bare missing-key error. This path may re-offer even after a skip —
  the user just asked a question, so the help is in context.
- **Manually**: Settings → General → "重新运行首次设置" re-opens the
  sheet at any time (also the way to preview it after setup).

## The sheet

One sheet on the panel (not a wizard — the round-2 non-goal stands):
header (icon, welcome, one line on what to do and that everything stays
on this Mac), then four blocks and a footer.

1. **Connect a model** — embeds `ModelSettingsView` itself (with its
   response-mode section hidden via a defaulted `showsResponseModes`
   flag, so Settings is unchanged). This is the reuse the spec asked
   for, taken one step further than extracting the cloud section: the
   settings tab was already factored as a standalone view, so the sheet
   hosts the real thing — provider cards, per-provider key handling,
   test connection through the existing `validate(config:)`, Ollama
   probing, and CLI path detection can never drift between the two
   surfaces.
2. **Screen Recording** — status from `Permissions.hasScreenRecording`,
   one button to request it (`Permissions.requestScreenRecording`),
   status refreshed when the app reactivates. Non-blocking: Wisp can
   answer text questions without it; the row exists so the first
   screenshot question is not the first time the user hears about it.
3. **Summon shortcut** — the `toggleAssistant` recorder
   (⌃⌥Space by default), so the user leaves knowing how to call Wisp
   back, and can change it on the spot.
4. **Footer** — "打开完整设置" (opens the Settings window via
   `openSettings`), "稍后再说" (skip; sets the per-launch dismissal),
   and "开始使用", which re-evaluates readiness: if a path is now
   configured it closes; otherwise it stays and shows a one-line hint
   that any one block above is enough, or that skipping is fine.

## Non-goals (unchanged from the spec)

No account creation, no bundled keys, no telemetry on completion, no
multi-page wizard.

## Verification

- `OnboardingReadinessTests` (Linux harness + macOS suite): the full
  signal matrix and the panel-open offer policy.
- CI on both macOS jobs compiles the sheet and runs the suite.
- Still needs a human fresh-profile pass on a Mac (delete the app
  support directory + Keychain items, walk all three provider paths) —
  recorded here because neither Linux nor CI can click through a sheet.

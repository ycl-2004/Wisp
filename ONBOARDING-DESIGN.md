# First-run onboarding — design (issue #8, v3)

Branch: originally `feat/first-run-onboarding`; v3 (window instead of
sheet) landed as item 3 of the UX overhaul on
`fix/ux-overhaul-2026-11-02`. Builds on the round-2 spec in
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
decides from live state, looking only at the connection a question
would go to right now (Settings' provider kind):

- cloud selected: a Keychain key exists for the selected cloud provider
  **and** the effective base URL is non-empty;
- Ollama selected: `OllamaSupport.probe` reports `.running`;
- agent CLI selected: the selected CLI resolves to an executable through
  the provider's own `resolvePath` (the configured path first, then the
  default install locations).

A path that works but is not selected does not count: with the cloud
selected (the default) and no key, an installed Claude Code still leaves
the question to fail with the missing-key error the wizard replaces, and a
CLI user with a custom path must never be blocked for lacking a cloud key.
`AssistantModel` gathers the signals (`refreshOnboardingReadiness()`),
Ollama's probe being the only async input. The result is cached in
`onboardingNeeded` (computed at launch, debounced on settings/Keychain
changes — item 2 of the UX overhaul), so presentation paths only read.

### The one stored flag — display bookkeeping, not readiness

`AppSettings.hasShownFirstRunOnboarding` records only that the wizard
window has actually been presented once; it gates the first-launch
auto-open and nothing else. It is written by the window controller at
the moment of presentation (any entry point counts — the window *was*
shown), and a factory reset wipes it with every other setting, so a
reset install auto-opens again. Readiness itself stays derived as
above; the two must never be conflated.

## Triggers and the annoyance budget

- **First launch**: after the launch-time readiness refresh lands
  (AppDelegate awaits that specific task — the not-yet-computed cache
  must never be read as "not needed"), if setup is needed and the
  wizard has never been shown, it opens once on its own.
- **Panel show** (`PanelController.show` → `AssistantModel.panelDidShow`):
  offer at most once per launch, and never again after the user skipped
  it this launch (policy:
  `OnboardingReadiness.shouldOfferOnPanelOpen`).
- **Asking while unconfigured** (`send`): if `needsSetup`, present the
  wizard instead of firing the provider call that would fail with the
  bare missing-key error. This path may re-offer even after a skip —
  the user just asked a question, so the help is in context.
- **Manually**: Settings → General → "重新运行首次设置" re-opens the
  wizard at any time (also the way to preview it after setup).

All four go through `AssistantModel.presentOnboarding()`.

## The window (v3 — was a sheet in v2)

The v2 sheet hung on the 110pt borderless panel: wrong geometry (a
720pt sheet erupting from a bottom pill), wrong lifecycle (the panel's
idle dismissal could take it down mid-flow), wrong focus model. The
wizard is now a standalone titled window hosted by
`OnboardingWindowController` (width 560, height fitted to content and
capped at 640, centered on the active screen):

- `AssistantModel.showsOnboarding` is a **state mirror only**. The
  controller observes it: `true` presents (or brings the window
  forward), `false` dismisses. The user closing the window directly
  (title-bar button) funnels into the same close path.
- Close accounting is unchanged from the sheet era: when the window
  goes away, `onboardingWindowClosed()` records the per-launch skip if
  still unconfigured and re-derives readiness. Only the host changed —
  the dismissal is now collected by the controller instead of a sheet
  `onDismiss`.
- The panel's modal guardrail (`hasModalPresented`, UX item 1) still
  counts the wizard: while it is open the panel must not idle-dismiss
  (the user is likely off in a browser fetching a key). The window
  itself is an ordinary window and needs no such protection.
- The window carries the same screen-privacy treatment as the panel
  (it contains a key field), and its window ID joins the panel's
  capture exclusion list.

### Layout

The window's title bar carries "欢迎使用 Wisp", so the body header is a
single subtitle line stating the deal up front — only the first step
is required, the other two can be filled in anytime in Settings, and
everything stays on this Mac. Three numbered steps, each with a
必须/可选 (required/optional) chip:

1. **Connect a model** (required) — embeds `ModelSettingsView` itself
   (with its response-mode section hidden via a defaulted
   `showsResponseModes` flag, so Settings is unchanged). This is the
   reuse the spec asked for, taken one step further than extracting
   the cloud section: the settings tab was already factored as a
   standalone view, so the wizard hosts the real thing — provider
   cards, per-provider key handling, test connection through the
   existing `validate(config:)`, Ollama probing, and CLI path
   detection can never drift between the two surfaces. Its own
   ScrollView is the window's only scroll region when content exceeds
   the 640 cap. (Known cosmetic debt, recorded in the view: its inner
   padding is 18 vs the wizard's 20 — a 2pt left-edge offset shared
   with Settings; fixing it means touching the shared view.)
2. **Screen Recording** (optional) — status from
   `Permissions.hasScreenRecording`, one button to request it
   (`Permissions.requestScreenRecording`), status refreshed when the
   app reactivates. Non-blocking: Wisp can answer text questions
   without it; the row exists so the first screenshot question is not
   the first time the user hears about it.
3. **Summon shortcut** (optional) — the `toggleAssistant` recorder
   (⌃⌥Space by default), so the user leaves knowing how to call Wisp
   back, and can change it on the spot.

Footer: "打开完整设置" demoted to a link-style escape hatch (opens
the Settings window via `openSettings`), "稍后再说" (skip; sets the
per-launch dismissal), and "开始使用 Wisp", which re-evaluates
readiness: configured → **completion handoff** (below); otherwise it
stays and shows a one-line hint in a permanently reserved 16pt slot —
the footer never changes height, so the button cannot push the layout
around. The hint line says any one connection above is enough, or that
skipping is fine.

### Completion handoff

A successful "开始使用 Wisp" does not just close the window:
`AssistantModel.completeOnboarding()` closes it and immediately shows
the panel, so the user lands on the question input (the panel's
existing `panelDidShow`/focus-request path puts the cursor there).
First run thus ends where the first question begins.

## Non-goals (unchanged from the spec)

No account creation, no bundled keys, no telemetry on completion, no
multi-page wizard.

## Verification

- `OnboardingReadinessTests` (Linux harness + macOS suite): the full
  signal matrix and the panel-open offer policy. (The window plumbing
  is AppKit/SwiftUI and is covered by macOS CI compilation plus the
  manual pass below, same as the panel itself.)
- CI on both macOS jobs compiles the wizard and runs the suite.
- Still needs a human fresh-profile pass on a Mac (delete the app
  support directory + Keychain items, walk all three provider paths,
  confirm the first-launch auto-open and the completion handoff) —
  recorded here because neither Linux nor CI can click through a
  window.

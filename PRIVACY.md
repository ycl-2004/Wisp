# Wisp Privacy Policy

Last updated: 2026-09-01. Applies to Wisp for macOS.

## The short version

Wisp reads your screen only when you ask it to, and only the frontmost window
at that moment. It has no account system, no analytics SDK, no crash-reporting
SDK, and no background recording.

It is not, however, a fully offline app. **When you use a cloud provider, the
text of the page you are looking at — the whole page, not just the visible
part — and a screenshot of the current window are sent to the endpoint you
configured.** That is the entire point of the app, and it is the thing to
understand before pointing it at a page you would not paste into a chat box.

## What Wisp stores on your Mac

| What | Where |
| --- | --- |
| Conversation text and page-text snapshots | `~/Library/Application Support/Wisp/conversations.json` |
| API key | macOS Keychain, service `com.yichenlin.Wisp` |
| Settings, window positions, island position | `UserDefaults` for `com.yichenlin.Wisp` |
| Temporary CLI screenshots | A per-request `Wisp-*` directory in the macOS temporary directory, permissions `0700`; removed when the command ends |
| Optional debug capture | `~/Library/Application Support/Wisp/debug/`, only while that setting is on |

Screenshots are never written into the conversation file. Cloud and Ollama
requests keep them in memory. Codex, AGY, and Claude Code write attached
screenshots into a private temporary working directory because those CLIs take
image files or file paths. Wisp attempts to delete that whole directory when
the command succeeds, fails, times out, or is cancelled. A crash or forced
termination can prevent that cleanup; macOS manages and eventually clears its
temporary directory. The optional debug setting is separate, is off by default,
and overwrites a single fixed screenshot file.

`conversations.json` is plain, unencrypted JSON. It is protected by your user
account's file permissions and nothing more. Page text captured from a
logged-in page is stored there in full, up to the page-text limit, and is not
evicted by age — it stays until you delete it. Settings → Data → Reset removes
the conversation file, the debug files, and the Keychain entry.

The file is capped by the limits in Settings → Data: at the defaults, ten
conversations of thirty turns each with the maximum page text works out to
roughly 50 MB.

## What leaves your Mac

- **Cloud provider.** Your question, the captured page text, the current
  screenshot, and the recent conversation history go to the Base URL you
  configured. What that service logs, how long it keeps it, and who can read it
  are governed by that service's own policy, not by Wisp.
- **Ollama.** Requests go to your local Ollama by default and stay on the
  machine. If you point the Base URL at a remote host, they go there instead.
- **Codex CLI.** Wisp starts the local `codex` process, hands it a temporary
  directory for image input, runs it with `--ephemeral` and a read-only
  sandbox, and deletes that directory when the command ends. Codex's own
  account, network use, and server-side logging are outside Wisp's control.
- **AGY CLI.** Wisp starts the local `agy` process in a private temporary
  workspace with `--sandbox`. Attached screenshots are written there for AGY
  to read, and Wisp deletes the directory when the command ends. AGY's own
  account, network use, and server-side logging are outside Wisp's control.
- **Claude Code CLI.** Wisp starts the local `claude` process in a private
  temporary workspace with `--restricted`, exposes only the `Read` tool, and
  disables local session history with `--no-session-persistence`. Attached
  screenshots are the only files placed in that workspace, which Wisp deletes
  when the command ends. Claude Code's account, network use, and server-side
  logging are outside Wisp's control.
- **Update check.** If Settings → General → "Check for a new version at launch"
  is on, Wisp asks `api.github.com` once per launch for the latest release tag.
  The request carries no identifier beyond what any HTTP request carries — your
  IP address and a `Wisp/<version>` user agent. Nothing is downloaded or
  installed automatically. Turn it off and no request is made.

There is nothing else. No telemetry, no analytics, no crash reporting, no
sync service, no account.

## What Wisp reads while running, and never keeps

- The frontmost application's name and bundle identifier, to decide what to
  capture and whether it is excluded.
- The frontmost window's image, for the current request only.
- In a supported browser: the current tab's URL, title, selected text, and full
  page body, via Apple Events and an injected extraction script.

Capture happens when you press the shortcut, when you press Refresh, and when
you switch apps while the panel is open. It does not happen while the panel is
closed.

## Excluding things

Settings → Screen & Permissions → Excluded apps takes bundle identifiers.
Excluded apps are never captured and never scripted. Three password managers
are excluded out of the box.

**This exclusion is per application, not per site.** There is currently no way
to exclude a particular URL or domain while still using Wisp in that browser.
If you do not want a specific page read, do not summon Wisp on it.

## Permissions Wisp asks for

- **Screen Recording** — to capture the frontmost window. Without it Wisp still
  works, but sends no screenshot.
- **Automation / Apple Events** — to read the URL, title, and page text from a
  supported browser. Granted per browser, the first time Wisp reads from it.
  Full page text additionally needs "Allow JavaScript from Apple Events"
  enabled in that browser, per profile.
- **Accessibility** — only when the enhanced shortcut mode is selected, to
  observe Shift, Globe/Fn, modifier-only, or double-/triple-tap key events while
  another app is active. The standard Carbon shortcut does not need this access.
- **Network client** — to reach your configured endpoint, a remote Ollama, and
  the optional update check.

Wisp is not sandboxed. It needs Apple Events and unrestricted screen access to
do what it does.

## Your rights

Everything Wisp keeps is on your own machine, and you can read or delete all of
it with Finder and Keychain Access. Settings → Data → "Show in Finder" opens
the folder. Data already sent to a model provider is subject to that provider's
policy; ask them.

## Changes

Material changes to this policy will be noted in
[CHANGELOG.md](CHANGELOG.md) alongside the release that makes them.

## Contact

Open an issue at <https://github.com/ycl-2004/Wisp/issues>.

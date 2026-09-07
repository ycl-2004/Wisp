# Wisp Privacy Policy

Last updated: 2026-09-07. Applies to Wisp for macOS.

## The short version

Wisp captures on invocation, refresh, or preparing a question. It prefers the
target window, but falls back to a display capture if no window matches.
It has no account system, no analytics SDK, no crash-reporting
SDK, and no background recording.

It is not, however, a fully offline app. **When you use a cloud provider, the
available page text (depending on capture mode and extraction limits), and a
screenshot when attachment is enabled, are sent to the endpoint you
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

`conversations.json` is plain, unencrypted JSON. Wisp restricts its support
directory to `0700`, including existing installations when accessed. This
restricts other local accounts, not processes running as you, administrators,
backup software, or copies made earlier. Page text captured from a
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
  HTTP sessions use ephemeral storage with no cache, cookies, or stored HTTP
  credentials. Redirects are refused, so configure the final API Base URL.
  Remote endpoints must use HTTPS; HTTP is accepted only for localhost,
  127.0.0.1, and ::1. These controls do not disable system networking logs or
  prevent a configured API gateway from forwarding requests upstream.
- **Ollama.** Requests go to your local Ollama by default and stay on the
  machine. If you point the Base URL at a remote host, they go there instead.
- **Codex CLI.** Wisp starts the local `codex` process, hands it a temporary
  directory for image input, and uses app-server over stdio with an
  `ephemeral: true`, read-only thread and `approvalPolicy: never`. Wisp stops
  its own app-server and deletes that directory when the request ends. Codex's own
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
  This setting now defaults to off; existing saved choices are preserved.

Opening Ollama settings probes its configured endpoint for models. Opening AGY
settings can launch model discovery. Connection tests also contact the chosen
provider (API tests use a generated solid-color image, not your screen).
Clicking links opens their destinations in your browser. Wisp does not
automatically download remote Markdown images when rendering an answer.

CLI integrations have a wider boundary than direct API requests. AGY and
Claude Code currently receive prompt text in process arguments, which may be
observable locally. Codex receives its prompt on stdin, but uses the user's
CLI configuration. Wisp's temporary-directory cleanup and session flags do
not guarantee the absence of CLI logs, hooks, integrations, or extra network
traffic. Use direct API mode when this wider boundary is unacceptable.

There is nothing else. No telemetry, no analytics, no crash reporting, no
sync service, no account.

## What Wisp reads while running

- The frontmost application's name and bundle identifier, to decide what to
  capture and whether it is excluded.
- The target window's image, or a fallback display image, held in memory until
  replaced/released; optional debug output and CLI images are described above.
- In a supported browser: the current tab's URL, title, selected text, and full
  page body, via Apple Events and an injected extraction script.

For virtual-scrolling pages, the extraction script may temporarily keep a
`window.__wispCollector` object in the active page while it gathers text. Wisp
clears that object when extraction finishes or when the page does not need a
scroll pass. Wisp reads Chromium profile preferences only to check the
Apple-Events setting; it does not write Wisp data into the browser profile,
history, or cache.

Invocation captures an image before showing the panel. Page extraction waits
until Send, except explicit Refresh also reads text. Switching apps updates
the header and marks context stale; returning to the panel can capture again.
There is no continuous background recording. Capturing does not simulate a
system screenshot keyboard shortcut or issue a CDP screenshot command.
It does not imply absence of OS records, browser focus events, or observable
page-script/scroll activity. Standard Debug and Release builds exclude the
diagnostic capture and distributed remote-show entry points; development use
requires the additional `WISP_DIAGNOSTICS` compilation flag.

## Excluding things

Settings → Screen & Permissions → Excluded apps takes bundle identifiers.
Excluded apps are never captured and never scripted. Three password managers
are excluded out of the box.

**This exclusion is per application, not per site.** There is currently no way
to exclude a particular URL or domain while still using Wisp in that browser.
If you do not want a specific page read, do not summon Wisp on it.

## Keeping Wisp out of your screen shares

Settings → Permissions → Screen sharing requests hiding Wisp's windows using
the legacy `NSWindow.sharingType = .none` flag. It is on by default and leaves
Wisp usable locally, but is not a security boundary or a guarantee against
capture. Apple explicitly advises against relying on this value to prevent
capture. Check the receiving-side view with your actual macOS and recorder
versions before displaying sensitive content.

The setting does not guarantee hiding menu bar icons or system-owned dialogs.
Window enumeration may still expose Wisp even when a capture omits its pixels.
It does not alter browser focus events, clipboard events, or other applications'
activity records, and does not affect cameras or hardware capture devices.
Turn it off when recording Wisp demos. See [validation scope and results](docs/screen-privacy-validation.md)
for the tested configurations and remaining gaps.

## Permissions Wisp asks for

- **Screen Recording** — to capture the frontmost window. Without it Wisp still
  works, but sends no screenshot.
- **Automation / Apple Events** — to read the URL, title, and page text from a
  supported browser. Granted per browser, the first time Wisp reads from it.
  Full page text additionally needs "Allow JavaScript from Apple Events"
  enabled in that browser, per profile.
- **Accessibility** — for real scroll collection, and when the enhanced shortcut mode is selected, to
  observe Shift, Globe/Fn, modifier-only, or double-/triple-tap key events while
  another app is active. The standard Carbon shortcut does not need this access.
- **Network client** — to reach your configured endpoint, a remote Ollama, and
  the optional update check.

The menu bar icon is drawn by the system, not by a Wisp window, so the hiding
preference cannot apply to it and it appears in any recording or shared screen.
Settings → Screen sharing can hide the icon; the assistant panel then shows a gear
button, and the global shortcut still works. Wisp's Settings window is also visible
in Mission Control even while hiding is on, unlike the assistant panel and island.

Wisp is not sandboxed. It needs Apple Events and unrestricted screen access to
do what it does.

The exposure surface from invocation to answer — network egress, logging,
browser activity, local processes, and on-disk state — is inventoried in the
[end-to-end privacy audit](docs/privacy-audit-e2e-20260907.md), together with
what was verified on 2026-09-07 and what remains outside Wisp's control.

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

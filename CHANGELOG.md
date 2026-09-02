# Wisp release notes

## 0.3.0 — 2026-09-02

### Added

- **Automated regression and release-safety checks.** The new XCTest target
  covers Claude Code tool isolation, stream-result and auth parsing, prompt
  truncation, and private temporary-directory cleanup. GitHub Actions runs the
  tests, builds both Release architectures, verifies the signature, and rejects
  any package carrying `com.apple.security.get-task-allow`.

- **Claude Code joins Codex and AGY under Agent CLI.** Settings and the model
  menu now offer a third local CLI, reusing whichever Claude Code login is
  already on the Mac. It is the only one of the three that streams: with
  `--output-format stream-json --include-partial-messages` the answer arrives as
  `text_delta` events and is shown as it is written, where Codex and AGY both
  return one finished block. `thinking_delta`, `signature_delta` and
  `input_json_delta` are dropped, so reasoning and tool arguments never reach
  the answer. Screenshots travel the same way as AGY's — written into a
  temporary working directory and named by path — but Claude Code only reads
  files inside its workspace, so that directory is also the process's working
  directory; without it the screenshot is refused and the model answers from
  text alone while reporting that its read was denied. Measured against
  `claude 2.1.258`: a single-turn request at the default 60,000-character page
  limit reached roughly 180,000 tokens with no truncation, which is about two
  and a half times what AGY accepts, so the prompt budget here is 150,000
  estimated tokens rather than AGY's 56,000. There is no `claude models`
  command, so the model list is the documented aliases — sonnet, opus, haiku,
  fable — which track the latest release without a Wisp update. Testing the
  connection runs `claude auth status`, which answers both "is it installed"
  and "is it signed in" in about a fifth of a second without spending any model
  quota, and reports a missing login as its own error rather than letting the
  first real question fail.

- **AGY CLI support inside the Agent CLI section.** Settings and the model
  switcher can choose between the existing Codex CLI and the locally installed
  AGY CLI. Every request — with or without a screenshot — goes through AGY's
  JSON headless mode, in a temporary working directory that is removed when the
  request ends. AGY's headless input accepts text only and rejects an
  `image_url` content block, so a screenshot is written into that directory and
  named by path in the prompt, which AGY then reads from disk; this is the same
  shape the Codex provider already uses for image input. The executable is
  discovered at runtime and the model menu refreshes from `agy models`, so AGY
  updates are picked up without hardcoded version checks.
- **Context sent to AGY is capped, and the cut is declared.** AGY silently
  truncates its own input at roughly 71,400 tokens: 295,000 characters of page
  text went in, 71,407 tokens were counted, and the passage buried in the
  middle vanished while the model still answered as though it had read the
  whole page. Routing the same prompt through AGY's `stream-json` stdin channel
  behaved identically, so this is AGY's own limit rather than an argument-size
  problem. Wisp now fits the prompt to a measured budget itself, reusing the
  same head-75%/tail-25% truncation the capture path already applies, so the
  model is told what was dropped and roughly where. The budget of 56,000
  estimated tokens sits above the 60,000-character default page-text limit — a
  single-turn request at that default measures 67,877 tokens end to end and is
  passed through untouched — and below the point where AGY starts returning
  nothing at all. AGY carries about 30,400 tokens of fixed overhead before any
  of Wisp's own content; an attached screenshot adds only about 1,150, since
  AGY reads the file with a tool rather than inlining the image.
- **An empty answer from AGY is reported instead of shown as a blank reply.**
  AGY sometimes exits successfully with `status: SUCCESS` and an empty
  `response`, most often when the context reaches its input limit. That used to
  arrive as an answer with no text and no explanation; it now surfaces as an
  error naming the likely cause and pointing at the page-text limit.
- **A provider picker for the cloud endpoint, with six built-in vendors.** Settings → Model now leads with 服务商 instead of a bare Base URL field: pick OpenRouter, Google Gemini, OpenAI, Anthropic or 智谱 GLM and the Base URL, the model list and the key-console link all follow, with 自定义 keeping the old behaviour of typing any OpenAI-compatible address by hand. Each vendor carries three to five vetted models plus 自定义; the entry bar was OpenAI-compatible `chat/completions` **and** SSE streaming **and** `image_url` data-URL vision, since every Wisp request ships a screenshot. Groq is deliberately absent — its only vision model is still a preview — as is DashScope's mainland endpoint, whose Base URL now embeds a workspace ID and cannot be a fixed preset.
- **API keys are stored per provider.** The Keychain entry moved from one shared `api-key` to `api-key.<provider>`, so keys no longer overwrite one another when switching vendors; the key field, 清除 Key and 保存并测试连接 all act on the selected vendor only. A key is written when the field is done being edited — on blur, on return, on switching vendor, and on closing the window — rather than only when 保存并测试连接 is pressed, so filling one in and switching vendor no longer discards it. Writing on every keystroke would be worse than either: typing a key by hand would store `s`, then `sk`, then `sk-`, and switching vendor mid-way would leave a truncated key behind while the menu still marked that vendor as configured. An empty field never overwrites a stored key, since clearing one is what 清除 Key is for. An existing 0.2.x key is migrated at launch to whichever vendor its Base URL points at, reading the value actually written to `UserDefaults` rather than the registered default — 0.2.x shipped `api.openai.com` as that default and only wrote the key when the field was edited, so reading the current default would file an untouched OpenAI setup under OpenRouter, move its Base URL and model with it, and delete the only copy of the old entry. An install that never edited the field is pinned to the 0.2.x defaults instead; a fresh install is untouched and still starts on OpenRouter. Each vendor also remembers the model last chosen for it, so switching back does not re-send the previous vendor's model name to the new endpoint.
- The island's model menu gained a **服务商** section mirroring the settings page, marking vendors that have no key yet, so changing vendor no longer means opening Settings.
- **A capture mode setting, under Settings → 采集模式, with three levels.** *纯截图* sends only the window screenshot plus the page URL and title, injecting no script at all. *读取页面正文* (the default) also reads the page text, which is complete for ordinary pages. *允许滑动采集* additionally scrolls on-demand-rendered pages to collect the whole document; it needs Accessibility permission and briefly borrows the mouse pointer, so it is opt-in rather than the default.
- **Enhanced shortcut recording.** Settings → 权限 now keeps the standard `⌃⌥Space` path and adds raw-event recording for `Shift`, `Globe/Fn`, modifier-only keys, and double-/triple-tap sequences such as double-tapping Control. Enhanced mode uses Accessibility permission only while it is selected.
- **Full-document capture for on-demand-rendered pages** (Feishu Docs, Notion and similar), by injecting genuine system-level scroll events through `CGEvent`. These pages keep only the visible blocks in the DOM, so a single `body.innerText` stops mid-sentence at the bottom of the screen. Measured on a Feishu doc: driving the scroll container's `scrollTop` from 0 to 3726 left the rendered line count at 12 and the body text at 541 characters throughout, and a synthetic `WheelEvent` did nothing either — Chrome treats it as untrusted. Trusted `CGEvent` scrolling moved the same document from 1100 to 4469 characters over 28 steps, reaching the closing sentence. Collection stops when several consecutive steps yield nothing new, which is the only reliable end signal here: these documents load as they scroll, so `scrollHeight` keeps growing and the scroll container never reports itself at the bottom.
- The page scroll position is **restored exactly** after a collection pass, not reset to the top — the pointer is parked over the content, the page is scrolled back to the top for a known baseline, then returned to the user's original offset with an exact final step. Measured deviation: 0px.

### Changed

- **Both local CLIs share one command runner for their helper calls.**
  `codex --version`, `agy --version` and `agy models` each set up their own
  pipes; two of them attached a `Pipe` to stderr and never read it, which is the
  deadlock the streaming path already guards against and warns about in its own
  comments. Nothing was failing in practice — `codex --version` writes 18 bytes
  to stdout and nothing to stderr — but the trap sat one added startup warning
  away from firing. The shared runner drains stdout and stderr concurrently, and
  on timeout follows `SIGTERM` with `SIGKILL` a second later. That second signal
  is the part that mattered: without it a child that ignores `SIGTERM` holds the
  pipes open, both reads block forever and the call never returns, leaving
  Settings on 测试中… or 扫描中… with nothing to cancel it. A child that ignores
  `SIGTERM` now returns in 4.0 seconds against a 2-second timeout instead of
  hanging indefinitely.

- **The OpenAI model presets were stale and are refreshed.** `gpt-4o-mini` / `gpt-5-mini` / `gpt-5` gave way to the current `gpt-5.6-luna` / `terra` / `sol`, all three of which take image input. A fresh install now defaults to OpenRouter rather than a bare `api.openai.com` address it has no key for.
- **The 429 message no longer quotes OpenRouter's quota rules to every provider.** It states the generic shape — free tiers meter per minute and per day separately — and leaves the specifics to the rate-limit headers the response actually carries.

- **The header follows the active window on its own again — without reading the page.** While the panel is open, the app name, window title and URL keep up with whichever window is in front, including tab switches inside a browser, so the context no longer has to be refreshed by hand. This costs one `CGWindowList` title read per second, which starts no subprocess; the URL is asked for only when that title actually changes. Screenshots, page text and scroll collection are unaffected — they still happen only on open and on send. Following to a different page clears the text collected from the previous one rather than pairing a new URL with old content, and says so in the header; notes that need the user to act, such as a missing permission, survive the switch.
- **Capture no longer re-runs on its own when you switch apps or browser tabs.** Activating another app while the panel is open now only records the new target and marks the context stale; it no longer triggers a capture. Clicking a tab in Chrome reactivates Chrome, so the old behaviour scanned on every tab switch — with scroll collection enabled that meant the page moved by itself while the user was still browsing.
- **The panel appears before any page reading starts.** Opening it waits only for the screenshot, which has to be taken before the panel is on screen; reading the page text is no longer part of that wait. Previously the panel appeared only after the whole capture finished, so with scroll collection the user pressed the shortcut, saw nothing, and watched their page start scrolling on its own.
- **Scroll collection now happens when you press send, not when the panel opens.** Scrolling the page before the user has even decided what to ask reads as the machine acting on its own; doing it as the question is sent reads as paging through the document to answer it. A follow-up question about the same page does not scroll again — the collected text is reused until the context goes stale.
- **The panel no longer auto-hides while you are working in the app it captured.** Switching tabs in Chrome to find something is preparation for asking, so the idle countdown does not run there; it still runs once you move to an unrelated app.
- The model is now told explicitly whether the page text is **complete, truncated by the length cap, or never fully collected**, and these are reported as distinct conditions. When the text is known to be incomplete, the prompt requires the answer to name the sentence it stops at instead of deflecting with "there is more below".
- Page text truncation snaps to paragraph boundaries and the elision marker quotes the text on either side of the gap, so the model can tell which passage is missing rather than only how many characters.

### Fixed

- **Claude Code can no longer turn a partial stream into a successful saved
  answer.** A response now requires both a successful final `result` event and
  exit code 0; missing results, error results, and nonzero exits fail the turn,
  while any already displayed text is persisted with an explicit incomplete
  marker. `claude auth status` exit code 1 is now recognized as signed out.

- **The English build was sending the model a Chinese system prompt.** The catalog entry for the prompt carried one trailing newline the source string does not, so every lookup missed and fell back to the Chinese key — including its rule 5, "default to Simplified Chinese", which is exactly what pushes an English user's answer into Chinese. The 0.2.0 release fixed this once; rewording the prompt for capture modes reintroduced it. The English text now defaults to English rather than repeating the Chinese rule verbatim.
- **Sixteen multi-placeholder strings never resolved in English**, among them the menu bar's conversation counter, the context header's turn counter, and the HTTP-failure message. Their catalog keys were written in positional form (`%1$lld/%2$lld 个对话`) while both SwiftUI's `LocalizedStringKey` and Foundation's `LocalizationValue` look up the plain form (`%lld/%lld 个对话`), so each one fell through to the Chinese key. Keys are now plain; the translated values keep their positional specifiers, which is where they belong. Verified by diffing the compiler's extracted `.stringsdata` keys against the compiled `en.lproj` table: zero misses remain.

- Page text was read from the scrolling container rather than `document.body`, which returned *less* text on Feishu (606 characters versus 833) because the body and the breadcrumb live in separate subtrees.
- Lines shorter than four characters bypassed deduplication during scroll collection and were re-appended on every pass, so sidebar labels accumulated dozens of times over a long document.

### Security

- **Claude Code requests are isolated from the rest of the Mac.** Wisp now runs
  headless requests with `--restricted --tools Read --no-session-persistence`.
  The only file tool is Read, its workspace is a private `0700` temporary
  directory containing only this turn's screenshots, user/project settings are
  ignored, and Claude Code does not save a local session transcript.
- **Release builds no longer inherit `get-task-allow`.** Release configuration
  and documented packaging commands set
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, and CI rejects regressions.

### Validation

- All 11 XCTest cases pass on macOS with Xcode 26.6, covering enhanced
  shortcuts, CLI prompt truncation, private temporary-directory cleanup, and
  Claude Code event, authentication, isolation, and completion handling.
- The ad-hoc-signed Universal 2 Release contains both `arm64` and `x86_64`,
  reports `0.3.0 (build 5)`, omits `com.apple.security.get-task-allow`, and
  retains a valid signature after a ZIP round trip.
- `Wisp-macOS-universal.zip` contains no `__MACOSX` or AppleDouble `._` entries,
  and its published SHA-256 checksum verifies.

## 0.2.0 — 2026-09-01

### Added

- **English localization, with an in-app language picker.** The app ships English and Simplified Chinese and follows the system language by default; Settings → General can pin it to either language regardless of the system setting, and offers to restart. 285 strings are translated, including the context-header chips, error messages, capture notes, and the model system prompt — an English user's requests no longer carry a Chinese prompt whose default-language rule pushed the model toward Chinese answers. A conversation's default title is stored as a language-independent sentinel and localized at display time, so a conversation created in one language does not show that language's title in the other.
- **Launch at login**, via `SMAppService`, with a toggle under Settings → General. When macOS holds the login item for approval, Settings says so and links straight to Login Items & Extensions.
- **Update checking.** Settings → General can ask GitHub once for the latest release tag at launch, and the menu bar gains a "download" item when a newer version exists. It sends nothing about you or your usage, never downloads or installs on its own, and can be turned off completely.
- **The island can be dragged anywhere on the desktop.** In its desktop form, hold and drag it to any position; it is remembered across launches and clamped back on screen when displays change. While you drag, it collapses to the small circle and rides directly under the cursor, so a screen edge cannot refuse it. Its stored position is the circle's own center rather than the window's corner, which is what lets the circle sit flush against an edge — anchoring on the fixed 372pt window kept it 166pt away. Expanding no longer always grows from the middle: against the left edge the pill grows right, against the right edge it grows left. The notch form still snaps to the notch, and the assistant panel is unaffected. Settings → Screen & Permissions has a **Reset position** button.
- **Third-party notices** are bundled with the app and readable from Settings → General → Open-source licenses, and checked in as `THIRD-PARTY-NOTICES.txt`.
- **A way out of the conversation cap.** At the limit, the new-conversation button now offers to drop the least recently updated conversation, naming it and asking for confirmation, instead of being disabled.
- A **General** tab in Settings, holding startup, update, storage-recovery, and about controls.
- `LICENSE` (MIT), `PRIVACY.md`, and this changelog.

### Fixed

- Capture warnings now retain whether they require user action instead of inferring that state from localized text.
- The conversation-cap eviction confirmation remains reachable when the assistant panel is open without the conversation list on screen.
- Codex CLI responses that finish at the wall-clock timeout boundary are no longer reported as timed out after the process has already completed.

### Fixed

- **The Codex provider could hang forever, and its stop button was a lie.** The reader blocked in `FileHandle.availableData`, where `Task.isCancelled` is never observed, so a codex process that stopped emitting output was never terminated, its temporary directory — holding that turn's screenshot — was never cleaned, and the stream never ended. Cancellation and a new 240-second wall-clock timeout now terminate the process itself (`SIGTERM`, then `SIGKILL`), which is what actually unblocks the read. `codex --version` in the connection test got a timeout too.
- **The Codex provider could deadlock on its own stderr.** Only stdout was drained, so once codex filled the stderr pipe buffer — which its startup warnings can do — both sides stopped. stderr is now drained concurrently.
- **Being offline showed "Generating…" for up to five minutes with no error.** `waitsForConnectivity` was on, so requests waited out `timeoutIntervalForResource` instead of failing. It is now off, and transport errors are mapped to specific, actionable messages: no connection, host not found, cannot connect, TLS failure, and timeout.
- **A future version could silently erase every conversation.** Swift's synthesized `Decodable` ignores property default values, so adding *any* field to `Message`, `Conversation`, or `ContextSnapshot` — with or without a default — would have failed to decode every existing file, sending it down the corrupt-backup path with no message to the user. Those types now decode tolerantly, unknown fields are ignored, and one damaged record drops only itself rather than the whole file.
- **A conversation file written by a newer Wisp is no longer overwritten.** The `version` field was written but never read. It is now checked before decoding; a newer file puts the store in read-only mode for that run and says so, with an explicit archive-and-reset escape in Settings.
- **Corrupt-file backups grew without limit and were never mentioned.** Every failed load left a timestamped copy that nothing cleaned up; the conversation list simply appeared empty. Backups are now capped at the newest three, and the panel shows a dismissible banner naming the backup.

### Security

- **Diagnostic entry points are now Debug-only.** `--dump-context`, `--show`, and the `--render-*` flags shipped in the public build. `--dump-context` let any local process borrow Wisp's Screen Recording grant to write a screenshot and full page text to a known path, and `--show` was posted through `DistributedNotificationCenter`, which does not authenticate its sender, so any local app could trigger a capture. None of them are compiled into Release builds.

### Changed

- Release packaging drops `--sequesterRsrc` from the `ditto` command, so the archive no longer contains a `__MACOSX` folder. The signature still verifies after the round trip.
- `ProviderConfig` is `Sendable`, removing one Swift 6 concurrency warning.

### Validation

- Debug build is clean; a build with `SWIFT_STRICT_CONCURRENCY=complete` also succeeds.
- Tolerant decoding was checked against six hand-built files — a v1 file missing fields, a file carrying unknown future fields, a file with one unparsable message, a file with one unparsable conversation, a newer-version file, and malformed JSON — using the shipping model types.
- Version comparison was checked over eleven cases, including `v`-prefixes, unequal segment counts, and pre-release suffixes; the update check was run against the live GitHub API.
- Island dragging was verified with synthesized mouse events: the window lands pixel-exact on the drag delta, persists, resumes from the dropped position, still opens the panel on a click, and is clamped back on screen for both partly and wholly off-screen stored positions.
- Both localizations were rendered offline and inspected.

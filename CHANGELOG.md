# Wisp release notes

## Unreleased

### Added

- **A capture mode setting, under Settings → 采集模式, with three levels.** *纯截图* sends only the window screenshot plus the page URL and title, injecting no script at all. *读取页面正文* (the default) also reads the page text, which is complete for ordinary pages. *允许滑动采集* additionally scrolls on-demand-rendered pages to collect the whole document; it needs Accessibility permission and briefly borrows the mouse pointer, so it is opt-in rather than the default.
- **Full-document capture for on-demand-rendered pages** (Feishu Docs, Notion and similar), by injecting genuine system-level scroll events through `CGEvent`. These pages keep only the visible blocks in the DOM, so a single `body.innerText` stops mid-sentence at the bottom of the screen. Measured on a Feishu doc: driving the scroll container's `scrollTop` from 0 to 3726 left the rendered line count at 12 and the body text at 541 characters throughout, and a synthetic `WheelEvent` did nothing either — Chrome treats it as untrusted. Trusted `CGEvent` scrolling moved the same document from 1100 to 4469 characters over 28 steps, reaching the closing sentence. Collection stops when several consecutive steps yield nothing new, which is the only reliable end signal here: these documents load as they scroll, so `scrollHeight` keeps growing and the scroll container never reports itself at the bottom.
- The page scroll position is **restored exactly** after a collection pass, not reset to the top — the pointer is parked over the content, the page is scrolled back to the top for a known baseline, then returned to the user's original offset with an exact final step. Measured deviation: 0px.

### Changed

- The model is now told explicitly whether the page text is **complete, truncated by the length cap, or never fully collected**, and these are reported as distinct conditions. When the text is known to be incomplete, the prompt requires the answer to name the sentence it stops at instead of deflecting with "there is more below".
- Page text truncation snaps to paragraph boundaries and the elision marker quotes the text on either side of the gap, so the model can tell which passage is missing rather than only how many characters.

### Fixed

- Page text was read from the scrolling container rather than `document.body`, which returned *less* text on Feishu (606 characters versus 833) because the body and the breadcrumb live in separate subtrees.
- Lines shorter than four characters bypassed deduplication during scroll collection and were re-appended on every pass, so sidebar labels accumulated dozens of times over a long document.

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

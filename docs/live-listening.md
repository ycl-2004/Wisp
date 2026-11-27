# Live captions

Wisp captions what the other side of a meeting says, and one key sends their last few
seconds of words to the model for an answer you can say out loud. It is opt-in, it never
listens to your microphone for captions, and nothing about a meeting is written to disk.

This page replaces the earlier "live listening" design (recording sessions, transcripts on
disk, local speech models). That design was removed; see the release notes.

## Use

1. Settings → Audio: turn on **Enable voice**, choose who recognizes the speech (Apple
   on-device or Soniox cloud) and the language. Recognizer and language are locked while
   captions run.
2. Click the captions button in the panel header, press Control–Option–R, or use the menu
   bar, to turn captions on. They listen to everything this Mac plays (the meeting, a
   video, music), from every app except Wisp itself. There is no app to choose.
3. Without the Screen & System Audio Recording permission macOS delivers no audio. The
   strip says so and offers a button that opens System Settings.
4. The strip sits under the panel header: two lines, the newest words last. After ten seconds
   of silence the words dim, so old words do not read as new.
5. When the other side asks something, run a command that attaches their words:
   - **Quick Ask** (Control–Option–A): the last 10 seconds, no screenshot.
   - **Ask About Screen** (Control–Option–D): the last 30 seconds plus a screenshot.

   Both are ordinary commands (Settings → Commands). Any command can attach 0–30 seconds of
   captions, with or without a screenshot, on any shortcut. The default prompt asks for one
   or two sentences that can be said out loud, then at most three points, and tells the model
   that the transcript may contain misrecognized words.
6. Captions stop when you toggle them off, hide the panel, the Mac sleeps or locks, or
   recognition fails. A reason stays on the strip until dismissed.

A caption question waits up to one second for the words still being recognized to settle
(the question is usually the last thing said). The window is counted back from the latest
recognized word, not from the clock, so after a silence "what did they just ask" is still
the last thing said. If nothing was heard in the window, Wisp says so and sends nothing.

**Answer automatically (experimental)**, in Settings → Audio, off by default: when the
other side's words end in a question mark and then stay unchanged for one second, Wisp runs
the first command that attaches captions (Quick Ask by default). There are at least eight
seconds between two automatic questions, one question is asked once, and nothing is asked
while an answer is being prepared or streamed. Every automatic answer is a model request.
Automatic answers leave the input draft untouched and send only the caption command's material.

**Ask through the API connection**, on by default: caption questions use the API configured
in Settings → Model whatever connection the panel currently uses. An agent CLI starts a
process for each question, so the API usually produces the first words sooner.

## Recognition

| | Apple on-device (default) | Soniox cloud |
|---|---|---|
| Where the audio goes | Stays on this Mac | Streamed to Soniox while captions run |
| Languages at once | Only the one you choose | The one you choose plus English |
| Cost | Free | Billed by Soniox per minute of audio, on your own API key |
| Setup | macOS downloads the language model on first use | Enter a Soniox API key in Settings → Audio (stored in the Keychain) |

Apple on-device uses `SpeechAnalyzer` with `SpeechTranscriber`, reporting volatile and fast
results, so a guess is revised as audio arrives instead of waiting for a pause. If the
language is not supported on this Mac, captions stop with an error. Wisp never falls back
to a cloud service by itself.

Soniox uses the real-time WebSocket API (`stt-rt-v6`): 16 kHz 16-bit mono PCM, language
hints for the chosen language plus English, and endpoint detection. Final tokens are
committed with their own times; the non-final tail is the current guess. A rejected key or
exhausted quota arrives as the service's first response and stops captions with its message.

Languages offered: Simplified Chinese, Traditional Chinese, English, Japanese.

## Hold to ask

Settings → Audio → Hold to ask (unassigned by default). Holding the shortcut opens the panel
(capturing the frontmost app) and listens on the microphone only; releasing sends the words
with the current screen context in the current response mode. It uses the recognizer and
language chosen for captions and can run beside them, since captions listen to what the Mac
plays rather than the microphone. A hold shorter than 0.3 s sends nothing; after 60 s the
words are placed in the input box without sending, in case the key-up was missed. Wisp
discards the microphone recording. In a regular conversation, sent text enters chat history.
Turning off Enable Voice stops captions and the microphone, and cancels any voice question
still waiting to be sent.

## What is kept

- The recognized words: in memory only, and only the last 30 seconds, the longest window a
  command can attach. Turning captions off discards them.
- Caption questions and their answers: in a conversation that is never written to disk and
  is discarded when captions stop.
- No audio, transcript or session file is written.
- Kept across launches: the recognizer and language, the two switches above
  (UserDefaults), and the Soniox API key (Keychain).

Apple's screen/system-audio and microphone indicators stay visible; Wisp does not replace or
hide them. Captions do not identify speakers. Get the consent a meeting requires before
turning them on.

## Implementation notes

- `SCStream` delivers the Mac's audio at 48 kHz through a display filter that excludes no
  application, with Wisp's own audio excluded. Only the audio output is attached; the video
  side is configured to a 2×2 frame once a second and is not consumed. Captions used to
  listen to one chosen app; that left nothing on screen when the sound came from another
  app, and no way to switch while the remembered app was running.
- Hold to ask taps the default microphone with `AVAudioEngine`.
- Both recognizers implement one protocol (`SpeechFeed`) and share one resampler
  (`PCMConverter`), which keeps its state between buffers. Audio reaches a recognizer on the
  capture sink's serial queue, never on a realtime audio thread.
- `CaptionBuffer` holds committed words with their audio times and one volatile guess.
  A new guess replaces the previous one; committed words replace the guess they settle.
  Apple's final results are split into words so a window can cut between words; its volatile
  timestamps are not usable for that (every word reports the end of the guess), so a guess
  stays one piece.
- Each start has its own generation: results and failures from a session that was stopped
  cannot change the next one.
- The strip adds 52 points to the collapsed panel. While it shows, the panel does not
  dismiss itself when idle. Hiding the panel stops captions: Wisp never listens with nothing
  on screen.
- Moving the panel: one drag gesture covers the whole panel content, and the window follows
  the mouse by Wisp's own arithmetic, kept inside the visible screen. Buttons, menus, the
  input box and selectable text have their own gestures or AppKit views, which take
  precedence, so every other spot drags the panel, including on the first press from
  another app. The system's own window-drag entry points are not used: on this borderless,
  non-activating panel `NSWindow.performDrag(with:)` and SwiftUI's `WindowDragGesture`
  logged "Window move completed without beginning" and moved nothing under a real trackpad
  (they did move it under synthetic mouse events, which hid the problem), and
  `isMovableByWindowBackground` only works where the press reaches bare background.
  Resizing: a transparent overlay above the content claims the
  outer six points on the left, right and bottom (sixteen at the bottom corners), pins the
  opposite edge and honours the window's size limits. The top edge moves the panel rather
  than resizing it. The pointer never changes shape; the blue guide inside the border shows
  where the panel resizes.

Audio goes only to the recognizer. Caption questions send recognized text to the model and
attach a screenshot when the command asks for one. Manually run commands also include the
input draft.

## Measurements

All on one Apple Silicon Mac, 2026-11-18, macOS 27.2. These are smoke measurements, not
benchmarks.

- **Caption delay, Apple on-device.** Five synthetic sentences (system text-to-speech,
  Mandarin with English terms) played in QuickTime and captioned through the real app:
  the last words of each sentence appeared within 0.3 s of its audio ending, and the caption
  stopped changing 0.35–1.18 s after the sentence ended.
  `tools/live-captions/CaptionLatencyProbe.swift` repeats the recognizer part of this
  without the app.
- **Key to answer.** Quick Ask through the Codex CLI connection: the question was in the
  panel 0.8 s after the key and the complete answer 1.9 s after it.
- **Moving the panel by hand.** Five stand-in panels, one per mechanism, dragged on a
  trackpad: `WindowDragGesture` (3 presses) and `performDrag` (4 presses) never moved;
  a drag gesture that moves the window itself (9 presses), an AppKit view doing the same
  (7 presses) and `isMovableByWindowBackground` on bare background did. In the installed
  app with the mechanism now used, 5 of 5 hand drags moved the panel; with
  `WindowDragGesture`, 1 of 27 had.
- **Whole-Mac audio.** With music playing in another app, captions started from the
  shortcut and showed its lyrics, also right after a reinstall with no permission prompt.
- **English terms inside Mandarin, Apple on-device.** In the synthetic clips "RAG" came out
  as "w", "我" or "we" and "folder" as "filder", and the model then answered the wrong
  question. This is the reason the Soniox option exists.

Not measured or not exercised yet:

- Soniox with a valid key. The request, the response parser and the rejected-key path are
  covered (unit tests and one live request with an invalid key); caption delay and accuracy
  on Soniox are unknown.
- Answer automatically, end to end in the installed app.
- Human speech, several speakers, and real meetings in Zoom, Teams or Meet.

## Official references

- [ScreenCaptureKit audio streams and application-level filtering](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [AVAudioConverter sample-rate conversion (TN3136)](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)
- [Soniox WebSocket API](https://docs.soniox.com/api-reference/stt/websocket-api)
- [macOS privacy indicators](https://support.apple.com/en-gb/guide/mac-help/mchl50f94f8f/mac)

# Live listening



Wisp transcribes the microphone, a selected application's playback, or both into local, timestamped text. This is an opt-in session, not an always-on listener.

## Use

Voice input is a single line between the screen-context header and the normal AI
conversation. It never replaces the answer area with a recording page.

Settings → Audio carries the master switch. Turn voice input off and the row
disappears from the panel, the shortcuts no longer start a recording, a session
still running stops, and the rest of the audio settings are hidden with it.

1. In Settings → Audio, select Only me (microphone), Only the other side
   (application playback), or Both sides. Choose a language and optional audio
   retention. For application audio, refresh and select the source app here.
2. Click the microphone button in the assistant, or press Control–Option–R.
   Permissions are requested only when needed. The same row shows the latest
   recognition text; short-batch processing still has a few seconds of latency.
3. Click Stop or press Control–Option–R again. After trailing recognition drains,
   unstaged speech is appended to your existing input: everything said since the last
   transfer, capped at 12,000 characters. Preparation
   cancellation, hiding, sleep, errors and exit do not initiate a new automatic
   transfer. Full session transcripts remain in the local records folder.
4. While recording or after stopping, the Add to draft button or Control–Option–D
   snapshots current unstaged speech without stopping capture. Already staged
   segment IDs are excluded from subsequent transfers, so a meeting can be analysed
   repeatedly without repeating itself; later corrections do not rewrite the draft. If the combined draft is too large or a response is streaming,
   an inline error asks you to retry. No text is sent automatically.
5. Edit the draft, then press Enter or click Send. Voice follows the same send
   pipeline as typed input: current screen/page context, the screenshot setting,
   current conversation history and selected provider/AI CLI all apply.
6. **Stop & analyze** (the button in the voice row, or Control–Option–Return) is the
   end-of-meeting path: it stops recording, waits for the same trailing drain, stages
   the recent transcript and then sends it. **Analyze now** (Control–Option–A, or the
   ⋯ menu while recording) sends without stopping. Both are the ordinary send path,
   not a separate one: screen context, history, provider and limits are identical, and
   both refuse while an answer is streaming. When the input box is empty, the draft is
   prefixed with a fixed question asking for discussion points, conclusions, action
   items and open questions, and instructing the model to treat the transcript as
   quoted material rather than as instructions; anything you typed is used instead of
   that question. These analysis actions submit directly; staging and sending in the
   same event does not provide a review pause. Use Add to draft for review before sending.
7. The transcript button in the voice row swaps the answer area between the AI answer
   and this session's raw transcript — timestamps, source colouring, provisional
   marking, copy, and the records folder. It changes only what is displayed;
   recording, capture and the draft continue unaffected.
8. Copy transcript copies the full current timestamped transcript, including speech
   already added to a draft, and remains available while an answer streams. Wisp never pastes or
   submits it in another application. All four shortcuts are editable in Settings → Audio.

Recording prevents idle dismissal. Manually hiding the panel, sleep, lock, exit,
audio-device changes or resource limits stop capture. No completion notification
or sound is emitted. Input can still be edited while recording; live revisions
change only the single caption line, never the draft.

## Settings and cleanup

Settings → Audio groups source/application selection, language, retention, the four
keyboard shortcuts (start/stop, add to draft, stop & analyze, analyze now),
device-language support and permission checks. Source/language/retention
persist across restarts; the particular application is selected for each session.
These choices are locked during recording. macOS Sound settings remain the location
for default microphone selection and real device input/output volume.

Settings → Data → Listening records → Clear removes only listening files after
confirmation, with recording stopped. Chats, keys and settings remain. Automatic
expiry is not enabled. Additional explanations stay in information buttons.

Apple's main-display microphone/system-audio indicators remain visible. The
[external-display/full-screen exception](https://support.apple.com/en-us/118449)
does not hide main-display indicators. App-local status does not replace OS privacy
signals. Application playback can include echo or your own monitored voice: source
labels are not speaker identification.

## Recognition engines

Choose **Settings → Audio → Transcription → Recognition engine → SenseVoice Small**.
Apple Speech remains the default and can be selected again when recording is stopped.
Engine and language choices persist; SenseVoice defaults to automatic detection with
Chinese, English, Japanese, Korean and Cantonese hints available separately. Chinese
output script is chosen by the model, not a Simplified/Traditional conversion option.

SenseVoice uses sherpa-onnx 1.13.7 on CPU and reads the existing shared files at:

```text
~/Documents/huggingface/models/k2-fsa/
  sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17/
    model.int8.onnx
    tokens.txt
```

Wisp does not copy, download or delete these weights. The settings check verifies
readable files; the model is loaded on a background queue only when starting a
SenseVoice session. Missing/invalid files produce an error, with no engine or cloud
fallback. SenseVoice requires no Apple Speech authorization; selected capture
sources still require microphone or screen/system-audio access.

Input is converted to 16 kHz mono and decoded in the existing 1–4-second batches.
Captions are final batch results with approximate batch timestamps, not word-level
alignment. A hard batch boundary can split words. CPU inference runs serially away
from capture and UI queues. Stop drains with the existing ten-second deadline;
a native decode already running cannot be interrupted, but its late callbacks are
ignored after cancellation. Shared models are excluded from listening-data cleanup.

Sources: [official runtime package](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.7/Package.swift),
[Swift/C recognition API](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.7/swift-api-examples/SherpaOnnx.swift),
[model card](https://huggingface.co/FunAudioLLM/SenseVoiceSmall).

## Local records and limits

Each session has a UUID folder under
`~/Library/Application Support/Wisp/Listening/` containing:

- `session.json`: start/stop time, language, application name, retention choice,
  source-labeled segments, provisional/final flags, and a stop reason if applicable.
- `transcript.txt`: readable timestamped text, checkpointed every two seconds only when changed.
- Only when **Save audio** was selected: one or more `<source>-<part>.caf` PCM files.
  Each source has its own track. A format change starts another file. These are
  source recordings, not a mixed, synchronized video timeline.

Folders use the existing `0700` protection. Records are plaintext and remain
accessible to the current user and administrators; there is no encryption or
automatic history deletion. The folder button opens the current session; go up
one folder in Finder to see previous sessions. Delete individual sessions in Finder
when stopped, or use Settings → Data → Listening records → Clear. The separate
Delete all records and API keys action also removes chat records and keys.

A session stops after two hours, 200,000 transcript characters, 2,000,000 UTF-8 text
bytes, 7,200 segments, or
256 MiB of saved PCM per source (512 MiB combined maximum, plus container overhead).
The queue is bounded; sustained overload stops with an error instead of silently
dropping audio. Each source can create at most 128 audio parts. The archive admits at most 100
sessions and reserves space within a 2 GiB logical-file budget before starting:
32 MiB for text-only sessions, 544 MiB when saving audio (both source budgets plus
text/container headroom). This conservative check may refuse a session before the
folder reaches 2 GiB. Old records are never deleted automatically; organize them
in Finder to free capacity. Unexpected links or nested folders fail closed. Files
created by other processes, filesystem allocation/metadata, OS caches, and backups
are outside this budget. For a long meeting, leave audio retention off or start
another session after a limit is reached.
No video frames are saved.

## Implementation and trade-offs

- `AVAudioEngine` taps the default microphone. Buffers are copied before leaving
  the callback so the audio engine can safely reuse its storage.
- `SCStream` delivers selected application audio. Only audio output is consumed;
  screen frames are neither attached to the stream output nor persisted.
- In Apple Speech mode, `SFSpeechRecognizer` processes short, source-labeled batches sequentially with partial results.
  A single scheduler prevents microphone and application requests from competing
  for the on-device recognizer.
  Wisp checks `supportsOnDeviceRecognition` and requires on-device recognition.
  Unsupported or unavailable languages fail visibly; there is no cloud audio fallback.
  Language resource downloads/availability are managed by macOS.
- What lands in the input box is speech, not a log: no timestamps, and consecutive
  batches from the same source are merged into one turn. Recognition returns a batch
  every few seconds, so pasting it verbatim produced a stack of
  `[00:00:01–00:00:02] My microphone:` fragments — noise in the first thing the user
  reads, and in what the model receives. A speaker label is added only when the window
  actually contains both sources, and provisional text is marked once per turn rather
  than per batch. `transcript.txt` and the transcript view keep the full timestamps.
- The header's title area is a real drag handle (`performDrag`). The borderless panel
  sets `isMovableByWindowBackground`, which only applies where the click reaches bare
  background; once expanded, the message list covers the middle, so dragging there moved
  nothing. Buttons in the header keep their own clicks, and a drag still saves the frame.
- A transfer carries everything said since the previous one, bounded only by the
  12,000-character draft budget. It used to be a 90-second window, which quietly lost
  material: analysing every few minutes in a meeting meant the minutes between two
  presses never reached any request at all, surviving only in the local records. Already
  transferred segment IDs are still excluded, so consecutive transfers do not repeat
  themselves. At roughly 5 characters per second — faster than ordinary speech — the
  budget holds a bit over half an hour of continuous talking; beyond that the oldest
  batches are dropped. Trimming happens per recognition batch and before merging: a
  single speaker talking for half an hour merges into one turn, and trimming a merged
  turn could only cut mid-sentence.
- Analyze now does not wait for recognition in flight. Audio still queued when the key
  is pressed misses that request, and arrives in the next one — those are new segments,
  so they are not marked as already transferred. Stop & analyze does wait for the drain,
  which is why the end-of-meeting path does not lose the last sentence. A segment that
  is corrected after it was transferred (provisional becoming final under the same ID)
  is not sent again.
- The panel is resized by a transparent overlay above the SwiftUI content that claims
  the outer six points (sixteen at the corners). The borderless window is `.resizable`,
  but its native grab area is too thin to hit once the content view covers it. The
  overlay pins the opposite edge, honours the window's min/max sizes, and returns `nil`
  from `hitTest` everywhere else so buttons, hover and window dragging behave as before.
- A pause after at least one second is preferred as a batch boundary; continuous
  speech flushes after four seconds. Quiet audio is never discarded by the boundary
  detector. Recognition is sequential, so captions arrive a few seconds after speech,
  with additional delay depending on hardware. At most eight pending batches are
  retained. An individual request and stop-time draining each have a ten-second
  deadline. Temporary results remain labeled if finalization does not arrive;
  words near boundaries may be imperfect. This needs live long-meeting validation.
- This uses APIs available to Wisp's existing macOS 14 deployment target. A dedicated
  macOS 26 `SpeechAnalyzer` backend can be evaluated later without raising the
  minimum OS or requiring a bundled third-party model for this first version.
- The app displays only the latest caption line, with bounded full session text on
  disk and available by opening the session folder. Recognition handles speech/silence; there is no
  identity recognition or acoustic echo cancellation. Apple Speech uses a fixed
  locale; SenseVoice can automatically detect the language per batch.
- Errors stop both tracks. Reset invalidates callbacks before deleting files, so
  late recognition results cannot recreate a deleted session. At process exit,
  the last known text is checkpointed; the final partial phrase may be incomplete.

Audio is not sent to the configured LLM. Enter/Send or the two explicit analysis actions send
text, using the same screen-context/provider/history rules as ordinary chat. A local app or CLI
is not necessarily an offline model; cloud providers receive the explanation input.

## Validation

The regression suite covers transcript revision/finality, two-source ordering,
unstaged-text selection and budget, whole-batch trimming without a time cutoff,
the analysis draft's question fallback and its refusal while streaming, panel-resize
geometry and edge-only hit testing, persistence, buffer ownership, and native UI
rendering of every voice-row state and the transcript view at both panel widths. Build and test evidence for this change is recorded in `.fable/task.md`.
No compatibility or accuracy guarantee is made for Zoom, Teams, Meet, protected
video playback, Intel hardware, or mixed-language and multi-speaker meetings until
those paths have been exercised on the target system. OS and other software may
observe capture; no undetectability guarantee is provided.

## Official references

- [ScreenCaptureKit audio streams and application-level filtering](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [Live audio recognition](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio)
- [On-device request requirement](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [AVAudioEngine input node](https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode)
- [Copying sample buffer PCM](https://developer.apple.com/documentation/coremedia/cmsamplebuffercopypcmdataintoaudiobufferlist(_:at:framecount:into:))

## Privacy and growth audit (2026-09-09)

Recognition and checkpoint callbacks never submit a provider request. An explicit
stop can stage a local draft; Enter/Send and the explicit analysis actions transmit text,
including normal screen context. Clipboard writing is an explicit Copy action and may be observed by clipboard
managers or Universal Clipboard. Pasting elsewhere follows that application's privacy
behavior. The main panel uses an AppKit container around NSHostingView so SwiftUI
content changes cannot override its resize bounds.

The listening view lives inside the existing protected assistant panel and creates
no separate completion window. macOS microphone/system-audio indicators and permission
prompts remain visible. The legacy window-sharing flag is a request, not a universal
capture guarantee; previous local capture evidence does not validate this audio
session against every recorder. See [Apple's capture-flag documentation](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)
and [macOS privacy indicators](https://support.apple.com/en-gb/guide/mac-help/mchl50f94f8f/mac).

Conversation storage defaults to ten conversations of thirty user turns. This is
a count limit, not an absolute byte limit: ordinary manually entered text, model
responses, configured higher limits and some manual archive files can still enlarge
it. Transcription itself does not grow `conversations.json`; only manually submitted
drafts become messages. PromptBuilder folds older screen context but retains
conversation message text, so repeated manual sends still increase model context
within those turn limits. No automatic transcript-to-history stream is present.

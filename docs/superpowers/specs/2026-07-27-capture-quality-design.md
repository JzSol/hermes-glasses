# Conversation capture quality: readable badges, recoverable audio

Date: 2026-07-27
Status: approved (user delegated all decisions)

Two independent failures in the "record this conversation" feature, plus one
usability gap. Fixed together because they share the same entry point.

## Problem 1 - every sighting saves as "Unnamed"

`BadgeReader.readBadge` OCRs `LensViewModel.crop(frame, to: snap.rect,
padding: 0.25)` - the whole YOLO **person** box, head to knees. A lanyard's
name line is ~0.8% of that crop's height.

Measured (synthetic person crop, badge text at the app's real scale):

| variant | 320x600 crop | 640x1200 crop |
|---|---|---|
| BadgeReader today | `[]` | `["Penn Medicine"]` |
| + `minimumTextHeight = 0.008` | `[]` | unchanged |
| torso band crop + upscale to 1000 px | `["Priya Hartan"]` | `["Priya Raman", "Penn Medicine"]` |

**Root cause: too few pixels on the badge**, not a Vision threshold.
Lowering `minimumTextHeight` is a no-op - the initial hypothesis, disproved
by the probe. The fix is to crop to the region where a lanyard hangs and
upscale it before recognition.

The glasses live stream compounds this: `startLiveStream` ladders
`.high -> .medium -> .low` and CLAUDE.md records that only `.low` reliably
opens on device, which is the left column.

Contributing: `badge_assist_enabled` defaults off, so the AI pass that exists
precisely for badges Vision cannot read never ran. There was no way to ask
for it on one encounter without flipping a global setting.

## Problem 2 - the transcript loses most of the conversation and lags

1. **Buffers are dropped between every utterance.** `emitFinalIfAny`
   (`HermesSpeechRecognizer.swift:213`) calls `tearDownCycle()` then
   `startRecognitionCycle()`. In between, `request` is nil and `append(_:)`
   returns early - silently discarding mic audio. A new
   `SFSpeechRecognitionTask` takes hundreds of ms to go live. In two-way
   conversation the other speaker starts talking into that hole.
2. **>=1.75 s of built-in lag.** A line exists only after 1.5 s of silence
   (`pauseInterval`) plus the 250 ms watchdog tick.
3. **Far-field speech.** iPhone mic, session mode `.default`, tuned for the
   wearer. The other party is frequently too quiet to trip the recognizer.
4. **`SFSpeechRecognizer` is a dictation model**, not a transcription engine:
   single speaker, degrades over long sessions.

The live recognizer is correct for the *command* loop (one utterance -> one
query) and wrong for continuous capture. Rather than tune it, capture stops
depending on it.

## Problem 3 - capture cannot be started from a cold start

The Record chip exists but is gated on `connectionState != .disconnected`
(`ContentView.swift:302`), so the user must first start a voice session -
which engages the AI brain, TTS and the whole query path - to record a
conversation that never uses any of it. Same mistake CLAUDE.md already
records for the test panel: "it exists to diagnose a broken setup, so
requiring a running session is backwards."

## Design

### Audio is the source of truth

A new `ConversationRecorder` streams the capture to
`Application Support/recordings/<id>.wav` (PCM16 mono 16 kHz) for the whole
session. It is fed by a new `HermesAudioManager.onRecordChunk` callback
fired **on the audio thread**, before the existing main-queue dispatch, and
writes on its own serial queue - file I/O at ~47 buffers/s must not land on
main. The recorder never consults the recognizer, so none of the four faults
above can lose audio.

The WAV header is written up-front with placeholder sizes and patched on
close, so a crash mid-capture still leaves a playable prefix.

At stop, `TranscriptionService` runs `SFSpeechURLRecognitionRequest` over the
finished file: the whole conversation in one request, no restarts, no 1.5 s
finalization, `addsPunctuation = true`. That removes faults 1, 2 and 4. The
result replaces the live transcript in the saved encounter.

Fault 3 (far-field) is acoustic and cannot be fixed in software here. The
recording is kept on disk so it can be re-transcribed later by a better
engine without asking the user to repeat the conversation.

The live recognizer keeps running during capture, but only to show the user
that something is being heard. Its buffer-dropping gap is still fixed
(`rotateCycle` starts the replacement request before cancelling the old one,
so `request` is never nil) because the same bug degrades the command loop.

### Badges get a region, not a person

`BadgeRegion` (pure, tested standalone) computes the lanyard band within a
person box and the upscale factor. `BadgeReader` runs two passes - the
upscaled band, then the whole crop - and merges the lines, so a badge worn
high or held in hand is still found. Parsing is unchanged: `BadgeParser`
stays conservative, because a confidently wrong name on someone's face is
worse than "Unnamed".

`badge_assist_enabled` stays **off** by default - the CLAUDE.md invariant
about spend and on-device promises holds. Instead PeopleView gains a
per-encounter "Read badges with AI" action: an explicit, one-encounter,
capped request, which is the dead end the old design had no answer for.

### Capture starts from the app

`startConversationCapture` learns to bring up the mic itself when no session
is running, and the Record action moves into the session screen's quick
actions next to Lens / People / Map / Log. Recording engages mic + camera +
recorder only - never the bridge, the provider, or TTS.

## Testing

- `tests/badge-region/` - pure band geometry and upscale factors.
- `tests/conversation/` - extended for transcript replacement.
- The OCR probe above is kept as `tools/ocr-probe.swift` so the pixel claim
  can be re-measured rather than re-argued.

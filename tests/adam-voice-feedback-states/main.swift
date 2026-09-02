// Standalone tests for Adam's pause, presentation, and finish-phrase policy.
// Build with:
//   xcrun swiftc HermesGlasses/Services/AdamVoiceFeedbackPolicy.swift \
//     tests/adam-voice-feedback-states/main.swift -o /tmp/adam-voice-feedback-tests \
//     && /tmp/adam-voice-feedback-tests

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    expect(got == want, "\(label) (got \(got), want \(want))")
}

let t0 = Date(timeIntervalSince1970: 1_000)
var pause = AdamPauseGate()
let ticket = pause.begin(at: t0)
expectEqual(pause.deadline, t0.addingTimeInterval(15), "pause deadline is 15 seconds")
expect(!pause.isDue(ticket: ticket, at: t0.addingTimeInterval(14.99)), "pause is not early")
expect(pause.isDue(ticket: ticket, at: t0.addingTimeInterval(15)), "pause is due at 15 seconds")
expect(pause.consumeTimeout(ticket: ticket, at: t0.addingTimeInterval(15)), "timeout is consumed")
expect(!pause.consumeTimeout(ticket: ticket, at: t0.addingTimeInterval(16)), "timeout consumption is one-shot")

let stale = pause.begin(at: t0)
pause.reset()
expect(!pause.consumeTimeout(ticket: stale, at: t0.addingTimeInterval(15)), "reset invalidates stale ticket")
let duplicate = pause.begin(at: t0)
expect(pause.consumeTimeout(ticket: duplicate, at: t0.addingTimeInterval(15)), "new ticket can be consumed")
expect(!pause.consumeTimeout(ticket: duplicate, at: t0.addingTimeInterval(15)), "duplicate ticket cannot be consumed")

expectEqual(AdamVoiceFeedbackPolicy.phase(for: .wakeAcknowledged), .listening, "wake acknowledgement maps to listening")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .hearingSpeech), .hearingSpeech, "speech maps to hearing")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .paused), .paused, "pause maps to paused")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .transcribing), .transcribing, "transcription maps to transcribing")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .transcriptReady), .transcriptReady, "complete transcript maps distinctly")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .thinking), .thinking, "thinking maps to thinking")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .preparingVoice), .preparingVoice, "voice preparation maps distinctly")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .speaking), .speaking, "speaking maps to speaking")
expectEqual(AdamVoiceFeedbackPolicy.phase(for: .failed), .failure, "failure maps to failure")
expect(AdamVoiceFeedbackPolicy.phase(for: .hearingSpeech).usesWaveform, "hearing uses waveform")
expect(!AdamVoiceFeedbackPolicy.phase(for: .thinking).usesWaveform, "thinking uses pulse instead")

for phrase in ["That's it", "Thats it!", "THAT IS IT.", "That’s it…", "Thatʼs it", "ＴＨＡＴＳ ＩＴ"] {
    expect(AdamFinishPhrasePolicy.isStandaloneFinishPhrase(phrase), "finish phrase normalizes \(phrase)")
}
for phrase in ["do that's it", "that's it please", "that is it now", "that's"] {
    expect(!AdamFinishPhrasePolicy.isStandaloneFinishPhrase(phrase), "finish phrase rejects \(phrase)")
}

exit(failures == 0 ? 0 : 1)

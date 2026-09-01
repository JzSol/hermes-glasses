// Standalone tests for WakeWordGate. Build with:
//   xcrun swiftc HermesGlasses/Services/WakeWordGate.swift \
//     tests/wake-word/main.swift -o /tmp/wake-word-tests && /tmp/wake-word-tests

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    expect(got == want, "\(label) (got \(got), want \(want))")
}

let t0 = Date(timeIntervalSince1970: 1_000)
var gate = WakeWordGate()

// Armed mode is quiet: ambient speech never reaches the agent.
expectEqual(gate.handleFinal("what time is it", now: t0), .suppressed,
            "armed suppresses ambient speech")
expectEqual(gate.handlePartial("what time", now: t0), .suppressed,
            "armed suppresses ambient partials")
expectEqual(gate.state, .armed, "ambient speech leaves gate armed")

// Adam is a whole-token prefix, never a substring or a mid-utterance match.
expectEqual(gate.handleFinal("adamant disagreement", now: t0), .suppressed,
            "adamant is not a wake word")
expectEqual(gate.handleFinal("hello Adam", now: t0), .suppressed,
            "mid-utterance Adam is suppressed")
expectEqual(gate.handleFinal("Adamant", now: t0), .suppressed,
            "partial Adam token is suppressed")
expectEqual(gate.handleFinal("Hey Adam", now: t0), .suppressed,
            "old Hey Adam phrase is no longer accepted")
expectEqual(gate.handleFinal("Hei Adam", now: t0), .suppressed,
            "old Hei Adam phrase is no longer accepted")

// The single wake word is case-, punctuation-, and diacritic-tolerant.
expectEqual(gate.handleFinal("  ÁDAM!  ", now: t0), .prompt,
            "Adam tolerates punctuation and diacritics")
expect(gate.state.isAwaitingCommand, "Adam alone opens command window")
expectEqual(gate.handleFinal("what time is it?", now: t0.addingTimeInterval(1)),
            .submit("what time is it?"), "next final is the command")
expectEqual(gate.state, .armed, "submitted command rearms gate")

// Adam followed by a command submits the tail immediately and preserves its
// original spelling for the agent.
expectEqual(gate.handleFinal("Adam, pasaki laiku", now: t0),
            .submit("pasaki laiku"), "Adam submits command tail")
expectEqual(gate.handleFinal("ADAM", now: t0), .prompt,
            "Adam alone opens a fresh command window")
expectEqual(gate.handleFinal("  kā tev klājas? ", now: t0.addingTimeInterval(2)),
            .submit("kā tev klājas?"), "command keeps diacritics")

// A phrase without a tail must wait for the next final, not submit an empty
// query. A late next final after expiry is ambient and remains suppressed.
expectEqual(gate.handleFinal("Adam...", now: t0), .prompt,
            "punctuated Adam opens a command window")
expect(gate.timeout(now: t0.addingTimeInterval(8.1)),
       "expired initial command window rearms")
expectEqual(gate.handleFinal("late command", now: t0.addingTimeInterval(8.1)), .suppressed,
            "late command after timeout is suppressed")

// Cancellation and failures always return to wake-only mode.
expectEqual(gate.handleFinal("Adam", now: t0), .prompt, "wake before cancel")
expectEqual(gate.cancel(), .rearmed, "cancel rearms")
expectEqual(gate.handleFinal("Adam", now: t0), .prompt, "wake before failure")
expectEqual(gate.failed(), .rearmed, "failure rearms")

// Speaking wake signal: Adam interrupts speech and waits for the command,
// while ordinary speech during TTS remains suppressed.
gate.setSpeaking(true)
expectEqual(gate.handleFinal("hello there", now: t0), .suppressed,
            "ordinary speech during TTS is suppressed")
expectEqual(gate.handleFinal("Adam", now: t0), .interrupt,
            "Adam signals speaking interruption")
expect(gate.state.isAwaitingCommand, "speaking Adam opens command window")
expectEqual(gate.handleFinal("stop talking", now: t0.addingTimeInterval(1)),
            .submit("stop talking"), "speaking wake accepts next command")

// Adam plus a command while speaking can interrupt and submit in one turn.
gate.setSpeaking(true)
expectEqual(gate.handleFinal("Adam, what is this", now: t0),
            .interruptAndSubmit("what is this"),
            "speaking Adam with tail interrupts and submits")
expectEqual(gate.state, .armed, "interrupt-and-submit rearms")
gate.setSpeaking(false)
expectEqual(gate.state, .armed, "speaking false leaves gate armed")

// A successful response opens a fresh 30-second hands-free follow-up window.
var responseGate = WakeWordGate(followUpWindow: 30)
responseGate.setSpeaking(true)
expectEqual(responseGate.completed(now: t0), .followUpOpened,
            "response completion opens follow-up mode")
expect(responseGate.state.isFollowUp, "completed response is in follow-up state")
expectEqual(responseGate.remainingCommandWindow(now: t0), 30,
            "follow-up starts with a 30-second deadline")
expectEqual(responseGate.handleFinal("what about tomorrow?", now: t0.addingTimeInterval(2)),
            .submit("what about tomorrow?"),
            "follow-up command does not require Adam")

// Each successful reply resets the full follow-up window.
responseGate.setSpeaking(true)
let secondReply = t0.addingTimeInterval(20)
expectEqual(responseGate.completed(now: secondReply), .followUpOpened,
            "next reply reopens follow-up mode")
expectEqual(responseGate.remainingCommandWindow(now: secondReply), 30,
            "next reply resets the full follow-up deadline")

// Donzo is an exact end phrase: case, width, punctuation, and diacritics are
// tolerated, while longer phrases remain normal commands.
expectEqual(responseGate.handleFinal("DÓNZO!", now: secondReply), .followUpEnded,
            "standalone donzo ends follow-up mode")
expectEqual(responseGate.state, .armed, "donzo returns to wake-only mode")
responseGate.setSpeaking(true)
_ = responseGate.completed(now: secondReply)
expectEqual(responseGate.handleFinal("donzo please", now: secondReply),
            .submit("donzo please"), "longer donzo phrase reaches Hermes")

// Timeout and failure both return to wake-only behavior.
responseGate.setSpeaking(true)
_ = responseGate.completed(now: t0)
expect(responseGate.timeout(now: t0.addingTimeInterval(30.1)),
       "follow-up timeout rearms")
expectEqual(responseGate.handleFinal("late follow-up", now: t0.addingTimeInterval(31)),
            .suppressed, "speech after follow-up timeout needs Adam")
responseGate.setSpeaking(true)
_ = responseGate.completed(now: t0)
expectEqual(responseGate.failed(), .rearmed, "failed follow-up returns wake-only")

// Adam's own acknowledgement cue must never become the command that follows
// the wake word. Capture remains closed for every cue-originated event and
// opens only after the cue has fully finished.
var cueGate = WakeCueCaptureGate()
expect(cueGate.acceptsCapture, "capture starts open before a wake cue")
cueGate.beginCue()
expect(cueGate.isBlocking, "wake cue closes command capture")
expect(!cueGate.acceptsCapture, "wake cue audio cannot start a command")
cueGate.finishCue()
expect(cueGate.acceptsCapture, "capture opens after the wake cue")
cueGate.beginCue()
cueGate.cancel()
expect(cueGate.acceptsCapture, "cancelling a wake window cannot leave capture blocked")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

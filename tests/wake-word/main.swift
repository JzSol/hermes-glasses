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

// Explicit lifecycle events always return to armed mode.
expectEqual(gate.handleFinal("Adam", now: t0), .prompt, "wake before cancel")
expectEqual(gate.cancel(), .rearmed, "cancel rearms")
expectEqual(gate.handleFinal("Adam", now: t0), .prompt, "wake before completion")
expectEqual(gate.completed(), .rearmed, "completion rearms")
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

// Continuous follow-up windows last 30 seconds, accept a final without Adam,
// and extend while partial speech is changing.
var followUpGate = WakeWordGate(commandWindow: 8, followUpWindow: 30)
expect(followUpGate.openFollowUpWindow(now: t0),
       "response opens a follow-up window")
expect(followUpGate.isFollowUpWindow, "follow-up window is marked")
let originalDeadline = followUpGate.commandDeadline
expectEqual(followUpGate.handlePartial("and also", now: t0.addingTimeInterval(10)),
            .extended, "partial follow-up extends its deadline")
expect(
    followUpGate.commandDeadline != nil,
    "extended follow-up retains a deadline"
)
if let originalDeadline, let extendedDeadline = followUpGate.commandDeadline {
    expect(extendedDeadline > originalDeadline,
           "partial follow-up moves the deadline forward")
}
expectEqual(
    followUpGate.handleFinal("what about tomorrow?", now: t0.addingTimeInterval(11)),
    .submit("what about tomorrow?"),
    "follow-up final submits without Adam"
)
expectEqual(followUpGate.state, .armed, "follow-up submission rearms")
expect(!followUpGate.isFollowUpWindow, "submitted follow-up closes its window")

expect(followUpGate.openFollowUpWindow(now: t0),
       "each response can open a fresh follow-up window")
expect(
    followUpGate.timeout(now: t0.addingTimeInterval(30.1)),
    "follow-up timeout rearms after 30 seconds"
)
expectEqual(
    followUpGate.handleFinal("late follow-up", now: t0.addingTimeInterval(30.1)),
    .suppressed,
    "follow-up after timeout requires Adam"
)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

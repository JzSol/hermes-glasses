// Standalone tests for Adam's reversible manual-listening activation policy.
// Build with:
//   xcrun swiftc HermesGlasses/Services/AdamVoiceActivationPolicy.swift \
//     tests/adam-activation/main.swift -o /tmp/adam-activation-tests \
//     && /tmp/adam-activation-tests

import Foundation

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    expect(got == want, "\(label) (got \(got), want \(want))")
}

expectEqual(
    AdamVoiceActivationPolicy.mode(storedWakeWordEnabled: nil),
    .manual,
    "manual mode is the unstored default"
)
expectEqual(
    AdamVoiceActivationPolicy.mode(storedWakeWordEnabled: false),
    .manual,
    "stored manual preference is preserved"
)
expectEqual(
    AdamVoiceActivationPolicy.mode(storedWakeWordEnabled: true),
    .wakeWord,
    "stored wake-word preference is preserved"
)
expectEqual(
    AdamVoiceActivationPolicy.controlState(
        isStarting: false, isListening: false, isVoiceWindow: false
    ),
    .ready,
    "idle manual mode maps to the start control"
)
expectEqual(
    AdamVoiceActivationPolicy.controlState(
        isStarting: true, isListening: false, isVoiceWindow: false
    ),
    .starting,
    "capture setup maps to starting"
)
expectEqual(
    AdamVoiceActivationPolicy.controlState(
        isStarting: false, isListening: true, isVoiceWindow: true
    ),
    .listening,
    "open command window maps to listening"
)
expectEqual(
    AdamVoiceActivationPolicy.controlState(
        isStarting: false, isListening: true, isVoiceWindow: false
    ),
    .working,
    "active turn outside capture maps to working"
)
expectEqual(AdamManualListeningControlState.ready.title, "Start listening",
            "ready control has an accessible action title")
expect(!AdamVoiceActivationPolicy.shouldRunCapture(
    mode: .manual, manualListeningActive: false
), "manual idle suppresses microphone and recognizer resources")
expect(AdamVoiceActivationPolicy.shouldRunCapture(
    mode: .manual, manualListeningActive: true
), "manual start enables the shared capture pipeline")
expect(AdamVoiceActivationPolicy.shouldRunCapture(
    mode: .wakeWord, manualListeningActive: false
), "re-enabled wake mode restores background capture")

var gate = AdamManualListeningGate()
expect(gate.isIdle, "manual listening starts idle")
let first = gate.begin()
expect(first != nil && gate.isStarting, "manual start enters starting state")
expect(gate.begin() == nil, "duplicate tap while starting is rejected")
expect(gate.markListening(ticket: first!), "current start enters listening")
expect(gate.isListening, "listening state is visible")
expect(gate.begin() == nil, "duplicate tap while listening is rejected")

gate.stop()
expect(gate.isIdle, "stop returns manual listening to idle")
expect(!gate.markListening(ticket: first!), "stale async start cannot re-enable capture")
let second = gate.begin()
expect(second != nil && second != first, "manual listening can be safely re-enabled")
expect(gate.markListening(ticket: second!), "new start ticket becomes listening")

exit(failures == 0 ? 0 : 1)

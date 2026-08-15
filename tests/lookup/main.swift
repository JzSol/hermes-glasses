//
// Standalone tests for PersonLookupGate. No XCTest target, so build via:
//   xcrun swiftc \
//     HermesGlasses/Services/PersonLookupGate.swift \
//     tests/lookup/main.swift -o /tmp/lookup-tests && /tmp/lookup-tests
//
// The gate is the pure heart of the Lookup app: given person boxes and a
// clock, decide when someone is close enough, centered, and has stayed put
// long enough to snap. Face/badge checks happen outside (they need Vision)
// and report back via rejected()/fired().
//
import Foundation
import CoreGraphics

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}

// A close, centered person: tall box straddling the frame center.
let near = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8)
// Same person, barely moved - IoU with `near` stays high.
let nearShifted = CGRect(x: 0.32, y: 0.1, width: 0.4, height: 0.8)
// Too far: a short box.
let far = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
// Close but at the edge of the frame - not who the wearer is facing.
let offCenter = CGRect(x: 0.0, y: 0.1, width: 0.25, height: 0.8)
// A different close person: no overlap with `near`.
let other = CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8)

var config = PersonLookupGate.Config()
config.holdSeconds = 1.0
config.lapseSeconds = 0.5
config.firedCooldownSeconds = 8.0
config.rejectedCooldownSeconds = 2.0

// MARK: - Nothing fires without a qualifying person

var gate = PersonLookupGate(config: config)
var update = gate.update(personBoxes: [], at: 0)
expect(update.target == nil && update.progress == 0 && update.fire == nil,
       "empty frame: no target, no progress")

update = gate.update(personBoxes: [far], at: 0.1)
expect(update.target == nil, "a far person is not a target")

update = gate.update(personBoxes: [offCenter], at: 0.2)
expect(update.target == nil, "an off-center person is not a target")

// MARK: - Hold to fire

gate = PersonLookupGate(config: config)
update = gate.update(personBoxes: [near], at: 0)
expect(update.target == near, "a near centered person becomes the target")
expect(update.progress == 0, "progress starts at zero")
expect(update.fire == nil, "no fire before the hold completes")

update = gate.update(personBoxes: [nearShifted], at: 0.5)
expect(update.fire == nil, "still holding at half time")
expect(abs(update.progress - 0.5) < 0.01, "progress is elapsed/hold (got \(update.progress))")

update = gate.update(personBoxes: [nearShifted], at: 1.0)
expect(update.fire == nearShifted, "hold complete: fire with the person's box")
expect(update.progress == 1, "progress caps at 1")

// After firing, the gate waits for a verdict instead of re-firing.
update = gate.update(personBoxes: [nearShifted], at: 1.1)
expect(update.fire == nil && update.progress == 1,
       "no second fire while the verdict is pending")

// MARK: - The largest qualifying box wins

gate = PersonLookupGate(config: config)
let smaller = CGRect(x: 0.35, y: 0.3, width: 0.2, height: 0.5)
update = gate.update(personBoxes: [smaller, near], at: 0)
expect(update.target == near, "the closest (largest) qualifying person is the target")

// MARK: - Brief detector dropouts are forgiven

gate = PersonLookupGate(config: config)
_ = gate.update(personBoxes: [near], at: 0)
_ = gate.update(personBoxes: [near], at: 0.4)
update = gate.update(personBoxes: [], at: 0.6)
expect(update.progress > 0, "a dropped frame inside the lapse keeps progress")
update = gate.update(personBoxes: [near], at: 0.7)
expect(update.fire == nil, "not fired yet after the dropout")
update = gate.update(personBoxes: [near], at: 1.0)
expect(update.fire != nil, "hold completes across a brief dropout")

// A long absence resets.
gate = PersonLookupGate(config: config)
_ = gate.update(personBoxes: [near], at: 0)
_ = gate.update(personBoxes: [near], at: 0.4)
update = gate.update(personBoxes: [], at: 1.5)
expect(update.progress == 0, "an absence past the lapse resets progress")
update = gate.update(personBoxes: [near], at: 1.6)
expect(update.progress == 0, "the hold restarts when they come back")

// MARK: - A different person restarts the hold

gate = PersonLookupGate(config: config)
_ = gate.update(personBoxes: [near], at: 0)
_ = gate.update(personBoxes: [near], at: 0.8)
update = gate.update(personBoxes: [other], at: 0.9)
expect(update.target == other, "a new person becomes the target")
expect(update.progress < 0.2, "but their hold starts from zero (got \(update.progress))")
update = gate.update(personBoxes: [other], at: 1.0)
expect(update.fire == nil, "the old person's progress does not fire the new one")

// MARK: - rejected(): short cooldown, then try again

gate = PersonLookupGate(config: config)
_ = gate.update(personBoxes: [near], at: 0)
update = gate.update(personBoxes: [near], at: 1.0)
expect(update.fire != nil, "fires before the rejection")
gate.rejected(at: 1.0)
update = gate.update(personBoxes: [near], at: 1.5)
expect(update.target == nil && update.progress == 0,
       "inside the rejection cooldown nothing is tracked")
update = gate.update(personBoxes: [near], at: 3.1)
expect(update.target == near && update.progress == 0,
       "after the rejection cooldown the hold restarts")
update = gate.update(personBoxes: [near], at: 4.1)
expect(update.fire != nil, "and can fire again")

// MARK: - fired(): long cooldown so one person is not looked up twice

gate = PersonLookupGate(config: config)
_ = gate.update(personBoxes: [near], at: 0)
_ = gate.update(personBoxes: [near], at: 1.0)
gate.fired(at: 1.0)
update = gate.update(personBoxes: [near], at: 5.0)
expect(update.target == nil, "inside the fired cooldown nothing is tracked")
update = gate.update(personBoxes: [near], at: 9.1)
expect(update.target == near, "after the fired cooldown scanning resumes")

// MARK: - IoU helper

expect(abs(PersonLookupGate.iou(near, near) - 1) < 1e-6, "identical boxes have IoU 1")
expect(PersonLookupGate.iou(near, other) < 0.3, "disjoint-ish boxes score low")
expect(PersonLookupGate.iou(near, CGRect(x: 2, y: 2, width: 0.1, height: 0.1)) == 0,
       "disjoint boxes score zero")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

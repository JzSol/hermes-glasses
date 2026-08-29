//
// Standalone tests for GlassesKeyMap + GlassesKeyGestureDetector. Build + run:
//   xcrun swiftc HermesGlasses/Services/GlassesKeyMap.swift \
//     tests/glasses-keys/main.swift -o /tmp/glasses-keys-tests && /tmp/glasses-keys-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// Map defaults + persistence round-trip
let d = UserDefaults(suiteName: "glasses-keys-tests")!
d.removePersistentDomain(forName: "glasses-keys-tests")
let fresh = GlassesKeyMap.load(from: d)
expect(fresh == .defaults, "no stored map → defaults")
expect(fresh.action(for: GlassesKeySlot(key: 1, gesture: .single)) == .toggleListening, "default key1 tap = listening")
expect(fresh.action(for: GlassesKeySlot(key: 1, gesture: .double)) == .visualQuery, "default key1 double = visual query")
expect(fresh.action(for: GlassesKeySlot(key: 2, gesture: .single)) == .none, "key2 unassigned")
var m = fresh
m.set(.snapPhoto, for: GlassesKeySlot(key: 3, gesture: .double))
m.set(.none, for: GlassesKeySlot(key: 1, gesture: .single))
m.save(to: d)
let back = GlassesKeyMap.load(from: d)
expect(back.action(for: GlassesKeySlot(key: 3, gesture: .double)) == .snapPhoto, "saved slot restored")
expect(back.action(for: GlassesKeySlot(key: 1, gesture: .single)) == .none, "cleared slot stays cleared (not re-defaulted)")
d.set(["9.triple": "toggleListening", "1.single": "bogus"], forKey: GlassesKeyMap.storageKey)
expect(GlassesKeyMap.load(from: d).entries.isEmpty, "garbage entries ignored")

// Gesture detector
let t0 = Date(timeIntervalSince1970: 1_000)
var det = GlassesKeyGestureDetector()
expect(det.press(key: 1, at: t0) == nil, "first press pends")
expect(det.nextFlushAt != nil, "flush scheduled")
expect(det.flush(now: t0.addingTimeInterval(0.1)) == nil, "flush inside window → nothing yet")
let s = det.flush(now: t0.addingTimeInterval(0.5))
expect(s?.key == 1 && s?.gesture == .single, "flush after window → single")
expect(det.flush(now: t0.addingTimeInterval(1)) == nil, "nothing pending after flush")

var det2 = GlassesKeyGestureDetector()
_ = det2.press(key: 2, at: t0)
let dbl = det2.press(key: 2, at: t0.addingTimeInterval(0.3))
expect(dbl?.key == 2 && dbl?.gesture == .double, "two presses within 400 ms → double")
expect(det2.flush(now: t0.addingTimeInterval(2)) == nil, "double consumed the pending press")

var det3 = GlassesKeyGestureDetector()
_ = det3.press(key: 1, at: t0)
expect(det3.press(key: 1, at: t0.addingTimeInterval(0.6)) == nil, "second press after window is a new pending single")

var det4 = GlassesKeyGestureDetector()
_ = det4.press(key: 1, at: t0)
expect(det4.press(key: 2, at: t0.addingTimeInterval(0.1)) == nil, "different key does not pair")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

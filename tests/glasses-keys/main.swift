//
// Standalone tests for GlassesKeyMap. Build + run:
//   xcrun swiftc HermesGlasses/Services/GlassesKeyMap.swift \
//     tests/glasses-keys/main.swift -o /tmp/glasses-keys-tests && /tmp/glasses-keys-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let d = UserDefaults(suiteName: "glasses-keys-tests")!
d.removePersistentDomain(forName: "glasses-keys-tests")
let fresh = GlassesKeyMap.load(from: d)
expect(fresh == .defaults, "no stored map → defaults")
expect(fresh.action(forKey: 1) == .toggleListening, "default tap = listening")
expect(fresh.action(forKey: 2) == .visualQuery, "default double tap = visual query")
expect(fresh.action(forKey: 3) == .none, "triple tap unassigned")
expect(GlassesKeyMap.label(forKey: 3) == "Triple tap", "key 3 label")

var m = fresh
m.set(.snapPhoto, forKey: 3)
m.set(.none, forKey: 1)
m.save(to: d)
let back = GlassesKeyMap.load(from: d)
expect(back.action(forKey: 3) == .snapPhoto, "saved key restored")
expect(back.action(forKey: 1) == .none, "cleared key stays cleared (not re-defaulted)")
expect(back.action(forKey: 2) == .visualQuery, "untouched key kept")

d.set(["1.single": "rememberPerson", "1.double": "snapPhoto", "9": "toggleListening", "2": "bogus"], forKey: GlassesKeyMap.storageKey)
let migrated = GlassesKeyMap.load(from: d)
expect(migrated.action(forKey: 1) == .rememberPerson, "old 1.single form migrates to key 1")
expect(migrated.entries.count == 1, "old .double, unknown key and bogus action ignored")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

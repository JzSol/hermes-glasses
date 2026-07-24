//
// Standalone tests for LensLogAggregator. No XCTest target, build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Lens/LensLogAggregator.swift \
//     tests/lenslog/main.swift -o /tmp/lenslog-tests && /tmp/lenslog-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
func expectClose(_ got: Double, _ want: Double, _ label: String) {
    expect(abs(got - want) < 0.001, "\(label) (got \(got), want \(want))")
}

let t0 = Date(timeIntervalSince1970: 1_000_000)

// 1. A snap creates an entry: count 1, no time yet
var agg = LensLogAggregator()
expect(agg.isEmpty, "empty at start")
agg.recordSnap(label: "cup", at: t0)
expect(!agg.isEmpty, "not empty after a snap")
var e = agg.entries()
expect(e.count == 1 && e[0].label == "cup", "one cup entry")
expect(e[0].lookCount == 1, "snap sets count 1")
expectClose(e[0].totalLookTime, 0, "no time before a completed look")

// 2. A completed look adds its duration
agg.recordLook(label: "cup", duration: 3.5, at: t0.addingTimeInterval(4))
e = agg.entries()
expectClose(e[0].totalLookTime, 3.5, "look adds duration")
expect(e[0].lookCount == 1, "count unchanged by a look")

// 3. A second snap+look on the same label sums time and bumps count
agg.recordSnap(label: "cup", at: t0.addingTimeInterval(10))
agg.recordLook(label: "cup", duration: 1.5, at: t0.addingTimeInterval(12))
e = agg.entries()
expectClose(e[0].totalLookTime, 5.0, "durations sum")
expect(e[0].lookCount == 2, "count is 2 after two snaps")

// 4. Different labels stay separate and sort by total time desc
agg.recordSnap(label: "person", at: t0.addingTimeInterval(20))
agg.recordLook(label: "person", duration: 9.0, at: t0.addingTimeInterval(30))
e = agg.entries()
expect(e.count == 2, "two labels")
expect(e[0].label == "person", "longest total sorts first")
expect(e[1].label == "cup", "shorter total sorts second")

// 5. A look with no prior snap is ignored (defensive)
var agg2 = LensLogAggregator()
agg2.recordLook(label: "ghost", duration: 2.0, at: t0)
expect(agg2.isEmpty, "look without a snap is ignored")

if failures > 0 { print("\n\(failures) FAILURES"); exit(1) }
print("\nAll lenslog tests passed")

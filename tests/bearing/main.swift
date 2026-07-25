//
// Standalone tests for Bearing. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Navigation/NavigationTypes.swift \
//     HermesGlasses/Services/Navigation/Bearing.swift \
//     tests/bearing/main.swift -o /tmp/bearing-tests && /tmp/bearing-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectClose(_ got: Double, _ want: Double, _ tol: Double, _ label: String) {
    expect(abs(got - want) <= tol, "\(label) (got \(got), want \(want))")
}

let origin = MapCoordinate(lat: 0, lon: 0)

// MARK: - Initial bearing, cardinal directions

expectClose(Bearing.initial(from: origin, to: MapCoordinate(lat: 1, lon: 0)),
            0, 0.5, "due north is 0°")
expectClose(Bearing.initial(from: origin, to: MapCoordinate(lat: 0, lon: 1)),
            90, 0.5, "due east is 90°")
expectClose(Bearing.initial(from: origin, to: MapCoordinate(lat: -1, lon: 0)),
            180, 0.5, "due south is 180°")
expectClose(Bearing.initial(from: origin, to: MapCoordinate(lat: 0, lon: -1)),
            270, 0.5, "due west is 270°")

// Always normalised into 0..<360, never negative.
for lat in stride(from: -80.0, through: 80.0, by: 20) {
    for lon in stride(from: -170.0, through: 170.0, by: 20) {
        let b = Bearing.initial(from: origin, to: MapCoordinate(lat: lat, lon: lon))
        if b < 0 || b >= 360 {
            failures += 1
            print("FAIL bearing out of range at \(lat),\(lon): \(b)")
        }
    }
}
expect(true, "bearing is always within 0..<360")

// Same point is a degenerate case, not a crash.
expect(Bearing.initial(from: origin, to: origin).isFinite, "same point gives a finite bearing")

// MARK: - Relative bearing (where it is, given where I face)

expectClose(Bearing.relative(bearing: 90, heading: 90), 0, 0.001,
            "facing straight at it is 0°")
expectClose(Bearing.relative(bearing: 90, heading: 0), 90, 0.001,
            "target east while facing north is +90 (right)")
expectClose(Bearing.relative(bearing: 0, heading: 90), -90, 0.001,
            "target north while facing east is -90 (left)")
expectClose(Bearing.relative(bearing: 180, heading: 0), 180, 0.001,
            "directly behind is 180")

// The wrap-around cases are where naive subtraction breaks.
expectClose(Bearing.relative(bearing: 10, heading: 350), 20, 0.001,
            "wrap forward across north stays +20, not -340")
expectClose(Bearing.relative(bearing: 350, heading: 10), -20, 0.001,
            "wrap backward across north stays -20, not +340")
expectClose(Bearing.relative(bearing: 0, heading: 359), 1, 0.001,
            "one degree right across north")

for bearing in stride(from: 0.0, to: 360.0, by: 7) {
    for heading in stride(from: 0.0, to: 360.0, by: 11) {
        let r = Bearing.relative(bearing: bearing, heading: heading)
        if r <= -180.001 || r > 180.001 {
            failures += 1
            print("FAIL relative out of range: b=\(bearing) h=\(heading) → \(r)")
        }
    }
}
expect(true, "relative bearing always lands in (-180, 180]")

// MARK: - Human-readable direction

expect(Bearing.direction(relative: 0) == .ahead, "0 is ahead")
expect(Bearing.direction(relative: 15) == .ahead, "15 is still ahead")
expect(Bearing.direction(relative: -15) == .ahead, "-15 is still ahead")
expect(Bearing.direction(relative: 45) == .slightRight, "45 is a slight right")
expect(Bearing.direction(relative: -45) == .slightLeft, "-45 is a slight left")
expect(Bearing.direction(relative: 90) == .right, "90 is right")
expect(Bearing.direction(relative: -90) == .left, "-90 is left")
expect(Bearing.direction(relative: 170) == .behind, "170 is behind")
expect(Bearing.direction(relative: -170) == .behind, "-170 is behind")
expect(Bearing.direction(relative: 180) == .behind, "180 is behind")

expect(Bearing.Direction.ahead.label == "ahead", "ahead label")
expect(Bearing.Direction.right.label == "to your right", "right label")
expect(Bearing.Direction.behind.label == "behind you", "behind label")

// Every direction answers, and the boundaries are covered.
for degrees in stride(from: -180.0, through: 180.0, by: 1) {
    _ = Bearing.direction(relative: degrees).label
}
expect(true, "direction is total over the whole circle")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

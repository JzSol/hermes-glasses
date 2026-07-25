//
// Standalone tests for VisionRouting. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/VisionRouting.swift \
//     tests/vision-routing/main.swift -o /tmp/vision-routing-tests \
//     && /tmp/vision-routing-tests
//
// These pin down the rule that broke in the field: "are the glasses paired"
// is NOT "can a glasses session be created". Only eligibility decides.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectRoute(
    eligible: Bool, _ pref: PhoneModePreference, _ want: VisionRoute, _ label: String
) {
    let got = VisionRouting.route(glassesEligible: eligible, preference: pref)
    expect(got == want, "\(label) (got \(got), want \(want))")
}

// MARK: - Auto: follow the hardware

expectRoute(eligible: true, .auto, .glasses, "auto + eligible glasses → glasses")
expectRoute(eligible: false, .auto, .phone, "auto + no eligible glasses → phone")

// The regression: glasses paired but unreachable must NOT keep the glasses
// route. Eligibility is the only input, so this is the same case as above -
// the bug was upstream, in what got passed as `glassesEligible`.
expectRoute(eligible: false, .auto, .phone,
            "auto + paired-but-unreachable glasses → phone")

// MARK: - Always: the phone, whatever the hardware says

expectRoute(eligible: true, .always, .phone, "always + eligible glasses → phone")
expectRoute(eligible: false, .always, .phone, "always + no glasses → phone")

// MARK: - Off: never fall back

expectRoute(eligible: true, .off, .glasses, "off + eligible glasses → glasses")
expectRoute(eligible: false, .off, .glasses,
            "off + no glasses → glasses (and the session will fail honestly)")

// MARK: - Can a session start at all?

expect(VisionRouting.canStartSession(glassesEligible: true, preference: .auto),
       "auto + glasses can start")
expect(VisionRouting.canStartSession(glassesEligible: false, preference: .auto),
       "auto + no glasses can still start, on the phone")
expect(VisionRouting.canStartSession(glassesEligible: false, preference: .always),
       "always + no glasses can start")
expect(VisionRouting.canStartSession(glassesEligible: true, preference: .off),
       "off + glasses can start")
expect(!VisionRouting.canStartSession(glassesEligible: false, preference: .off),
       "off + no glasses is the ONLY dead case")

// MARK: - Is a phone fallback allowed after the glasses path fails?

expect(VisionRouting.mayFallBackToPhone(preference: .auto),
       "auto may fall back when the glasses path fails")
expect(VisionRouting.mayFallBackToPhone(preference: .always),
       "always is already the phone")
expect(!VisionRouting.mayFallBackToPhone(preference: .off),
       "off must never silently switch to the phone")

// MARK: - Totality

for pref in PhoneModePreference.allCases {
    for eligible in [true, false] {
        _ = VisionRouting.route(glassesEligible: eligible, preference: pref)
        _ = VisionRouting.canStartSession(glassesEligible: eligible, preference: pref)
    }
    _ = VisionRouting.mayFallBackToPhone(preference: pref)
}
expect(true, "routing is total over every preference and eligibility")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

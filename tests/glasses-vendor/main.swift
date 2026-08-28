//
// Standalone tests for GlassesVendor. Build + run:
//   xcrun swiftc HermesGlasses/Services/GlassesVendor.swift \
//     tests/glasses-vendor/main.swift -o /tmp/glasses-vendor-tests && /tmp/glasses-vendor-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

expect(GlassesVendor.storageKey == "glasses_vendor", "storage key")
expect(GlassesVendor.allCases.map(\.rawValue) == ["meta", "aisee"], "raw values are stable storage strings")
expect(GlassesVendor.meta.label == "Meta Ray-Ban" && GlassesVendor.aisee.label == "AiSee", "labels")
expect(GlassesVendor.meta.cameraLabel == "Ray-Ban camera" && GlassesVendor.aisee.cameraLabel == "AiSee camera", "camera labels")
expect(GlassesVendor.meta.supportsDisplay && !GlassesVendor.aisee.supportsDisplay, "only Meta has a display")
expect(GlassesVendor.meta.usesMetaSDK && !GlassesVendor.aisee.usesMetaSDK, "usesMetaSDK")

let d = UserDefaults(suiteName: "glasses-vendor-tests")!
d.removePersistentDomain(forName: "glasses-vendor-tests")
expect(GlassesVendor.load(from: d) == .meta, "default is Meta")
d.set("aisee", forKey: GlassesVendor.storageKey)
expect(GlassesVendor.load(from: d) == .aisee, "loads aisee")
d.set("garbage", forKey: GlassesVendor.storageKey)
expect(GlassesVendor.load(from: d) == .meta, "unknown value falls back to Meta")

// Eligibility: Meta ignores AiSee state, AiSee ignores Meta state, a wedge disqualifies AiSee
expect(GlassesVendor.glassesEligible(vendor: .meta, metaDeviceActive: true, aiseeConnected: false, aiseeWedged: false), "meta: active device → eligible")
expect(!GlassesVendor.glassesEligible(vendor: .meta, metaDeviceActive: false, aiseeConnected: true, aiseeWedged: false), "meta: aisee connection is irrelevant")
expect(GlassesVendor.glassesEligible(vendor: .aisee, metaDeviceActive: false, aiseeConnected: true, aiseeWedged: false), "aisee: connected → eligible")
expect(!GlassesVendor.glassesEligible(vendor: .aisee, metaDeviceActive: true, aiseeConnected: false, aiseeWedged: false), "aisee: meta device is irrelevant")
expect(!GlassesVendor.glassesEligible(vendor: .aisee, metaDeviceActive: false, aiseeConnected: true, aiseeWedged: true), "aisee: wedged → not eligible")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

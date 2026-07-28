//
// Standalone tests for BadgeRegion. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/BadgeRegion.swift \
//     tests/badge-region/main.swift -o /tmp/badge-region-tests \
//     && /tmp/badge-region-tests
//
// NOTE: this file ends in print(...) then exit(...). New assertions go
// ABOVE those two lines or they never run.
//
import CoreGraphics
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }
func expectClose(
    _ got: CGFloat, _ want: CGFloat, _ label: String, tolerance: CGFloat = 0.0001
) {
    if abs(got - want) <= tolerance { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}

// MARK: - The band sits inside the crop

let band = BadgeRegion.band
expectTrue(band.minX >= 0 && band.maxX <= 1, "band stays within the crop horizontally")
expectTrue(band.minY >= 0 && band.maxY <= 1, "band stays within the crop vertically")
expectTrue(band.height > 0 && band.width > 0, "band is non-empty")

// A lanyard hangs on the chest: the band must exclude the head and the legs,
// which is the whole point of cropping rather than reading the person box.
expectTrue(band.minY > 0.1, "band excludes the head")
expectTrue(band.maxY < 0.9, "band excludes the legs")

// It should still be the majority of the torso - a badge worn high or a
// person cropped loosely must not fall outside it.
expectTrue(band.height >= 0.4, "band covers most of the torso")
expectTrue(band.width >= 0.8, "band trims very little horizontally")

// MARK: - Upscale factor

expectClose(
    BadgeRegion.upscaleFactor(forShortSide: 1000), 1,
    "a band already at the target is not touched")
expectClose(
    BadgeRegion.upscaleFactor(forShortSide: 4000), 1,
    "a large band is never shrunk - that would discard the pixels we want")
expectClose(
    BadgeRegion.upscaleFactor(forShortSide: 500), 2,
    "a half-size band is doubled")
expectClose(
    BadgeRegion.upscaleFactor(forShortSide: 250), 4,
    "a quarter-size band is quadrupled")

// The failing case from the probe: a .low glasses stream person box is a few
// hundred pixels wide, and must be magnified, not passed through.
let lowResBandShortSide = 320 * BadgeRegion.band.width
expectTrue(
    BadgeRegion.upscaleFactor(forShortSide: lowResBandShortSide) > 3,
    "a low-res glasses crop is magnified substantially")

// Degenerate input must not produce a zero or infinite factor - a crop can
// come back empty when the person box is clipped at the frame edge.
expectClose(BadgeRegion.upscaleFactor(forShortSide: 0), 1, "zero short side is safe")
expectClose(
    BadgeRegion.upscaleFactor(forShortSide: 1), BadgeRegion.maximumUpscale,
    "a one-pixel band is capped, not magnified a thousandfold")

// MARK: - Upscaled size

// Short side 400 -> factor 1000/400 = 2.5.
let small = BadgeRegion.upscaledSize(for: CGSize(width: 400, height: 500))
expectClose(small.width, 1000, "width scales by the short-side factor")
expectClose(small.height, 1250, "height scales by the same factor")
expectTrue(
    min(small.width, small.height) >= BadgeRegion.minimumShortSide,
    "the upscaled band reaches the target short side")

let big = BadgeRegion.upscaledSize(for: CGSize(width: 2000, height: 3000))
expectClose(big.width, 2000, "an already-large band keeps its width")
expectClose(big.height, 3000, "an already-large band keeps its height")

// Aspect ratio must survive - a stretched badge reads worse, not better.
let wide = BadgeRegion.upscaledSize(for: CGSize(width: 900, height: 300))
expectClose(
    wide.width / wide.height, 3, "aspect ratio is preserved", tolerance: 0.01)

print(failures == 0 ? "\nAll BadgeRegion tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)

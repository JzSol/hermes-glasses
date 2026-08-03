//
// Standalone tests for BadgeCrop. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/BadgeRegion.swift \
//     HermesGlasses/Services/Social/BadgeCrop.swift \
//     tests/badge-crop/main.swift -o /tmp/badge-crop-tests \
//     && /tmp/badge-crop-tests
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

// MARK: - Vision's bottom-left origin is flipped exactly once, here.

let visionRect = CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.1)
let flipped = BadgeCrop.box(
    label: "conference_lanyard", confidence: 0.9, visionRect: visionRect
)
expectClose(flipped!.rect.minX, 0.4, "x is unchanged by the flip")
// Vision maxY 0.7 -> top-left minY 0.3
expectClose(flipped!.rect.minY, 0.3, "y is flipped to a top-left origin")
expectClose(flipped!.rect.width, 0.2, "width survives the flip")
expectClose(flipped!.rect.height, 0.1, "height survives the flip")
expectEqual(flipped!.label, "conference_lanyard", "the label is carried")

// A box at the very top in Vision coords lands at the very top after flipping.
let topInVision = BadgeCrop.box(
    label: "corporate_id", confidence: 0.9,
    visionRect: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1)
)
expectClose(topInVision!.rect.minY, 0, "a Vision-top box maps to y = 0")

// MARK: - Confidence floor

expectTrue(
    BadgeCrop.box(label: "corporate_id", confidence: 0.05,
                  visionRect: visionRect) == nil,
    "a low-confidence detection is dropped")
expectTrue(
    BadgeCrop.box(label: "corporate_id",
                  confidence: BadgeCrop.minimumConfidence,
                  visionRect: visionRect) != nil,
    "a detection exactly at the floor is kept")

// MARK: - Picking one box
//
// A person can wear two badges (clinical stacks routinely do). Read the
// most confident one rather than merging two tags into one identity.

let boxes = [
    BadgeBox(label: "clinical_id", confidence: 0.55,
             rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)),
    BadgeBox(label: "conference_lanyard", confidence: 0.81,
             rect: CGRect(x: 0.5, y: 0.3, width: 0.2, height: 0.1)),
]
expectEqual(BadgeCrop.best(boxes)?.label, "conference_lanyard",
            "the most confident box wins")
expectTrue(BadgeCrop.best([]) == nil, "no boxes means no badge")

// MARK: - Padding, and never off the edge
//
// A tight box clips the last printed line; the pad recovers it. Clamping
// matters because a badge at the frame edge is the common handheld case.

let padded = BadgeCrop.padded(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1))
expectTrue(padded.width > 0.2, "padding widens the box")
expectTrue(padded.height > 0.1, "padding heightens the box")

let atEdge = BadgeCrop.padded(CGRect(x: 0, y: 0, width: 0.2, height: 0.1))
expectClose(atEdge.minX, 0, "padding cannot push the box off the left edge")
expectClose(atEdge.minY, 0, "padding cannot push the box off the top edge")

let atFarEdge = BadgeCrop.padded(
    CGRect(x: 0.85, y: 0.9, width: 0.15, height: 0.1))
expectClose(atFarEdge.maxX, 1, "padding cannot push the box off the right edge")
expectClose(atFarEdge.maxY, 1, "padding cannot push the box off the bottom edge")

let wholeFrame = BadgeCrop.padded(CGRect(x: 0, y: 0, width: 1, height: 1))
expectClose(wholeFrame.width, 1, "a full-frame box stays full-frame")

// A caller can ask for a different padding fraction than the badge default
// (BadgePortrait pads faces by 0.25, not BadgeCrop's 0.12) and still gets
// the same grow-and-clamp behaviour.
let widerPadded = BadgeCrop.padded(
    CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1), by: 0.25)
expectClose(widerPadded.width, 0.3, "a custom fraction widens by that amount")
expectClose(widerPadded.height, 0.15, "a custom fraction heightens by that amount")

let widerAtEdge = BadgeCrop.padded(
    CGRect(x: 0, y: 0, width: 0.2, height: 0.1), by: 0.25)
expectClose(widerAtEdge.minX, 0, "a custom fraction still clamps at the left edge")
expectClose(widerAtEdge.minY, 0, "a custom fraction still clamps at the top edge")

// MARK: - Unit rect to pixels

let pixels = BadgeCrop.pixelRect(
    for: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5),
    in: CGSize(width: 400, height: 800)
)
expectClose(pixels!.minX, 200, "x scales to pixels")
expectClose(pixels!.minY, 200, "y scales to pixels")
expectClose(pixels!.width, 100, "width scales to pixels")
expectClose(pixels!.height, 400, "height scales to pixels")

expectTrue(
    BadgeCrop.pixelRect(for: CGRect(x: 0, y: 0, width: 0.001, height: 0.001),
                        in: CGSize(width: 20, height: 20)) == nil,
    "a sub-pixel box is not a crop")
expectTrue(
    BadgeCrop.pixelRect(for: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                        in: .zero) == nil,
    "a zero-sized image has no crop")

// MARK: - The magnifier is the one BadgeRegion already measured

let small = BadgeCrop.upscaledSize(for: CGSize(width: 120, height: 60))
expectEqual(small, BadgeRegion.upscaledSize(for: CGSize(width: 120, height: 60)),
            "badge crops use BadgeRegion's measured upscale, not a new one")

print(failures == 0 ? "\nAll BadgeCrop tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)

//
// Standalone tests for FaceAlignment. No XCTest target:
//   xcrun swiftc \
//     HermesGlasses/Services/People/FaceAlignment.swift \
//     tests/face-align/main.swift -o /tmp/face-align-tests \
//     && /tmp/face-align-tests
//
// The transform is shared by import and live snap. If the two sides ever
// disagree, every similarity in the system silently becomes meaningless -
// nothing crashes, nothing logs, faces simply stop matching - so the
// geometry is pinned here rather than eyeballed.
//
import Foundation
import CoreGraphics

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.01) -> Bool {
    abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
}

let tL = FaceAlignment.templateLeftEye
let tR = FaceAlignment.templateRightEye

// MARK: - The eyes land on the template, whatever the input

// A level face, arbitrary scale and offset.
var t = FaceAlignment.transform(leftEye: CGPoint(x: 100, y: 200),
                                rightEye: CGPoint(x: 200, y: 200))
expect(near(CGPoint(x: 100, y: 200).applying(t), tL), "left eye lands on the template")
expect(near(CGPoint(x: 200, y: 200).applying(t), tR), "right eye lands on the template")

// A much smaller face far from the origin - this is the roster's tail, where
// the face is ~50px in a 512px frame.
t = FaceAlignment.transform(leftEye: CGPoint(x: 1000, y: 40),
                            rightEye: CGPoint(x: 1020, y: 40))
expect(near(CGPoint(x: 1000, y: 40).applying(t), tL), "a small distant face still aligns (left)")
expect(near(CGPoint(x: 1020, y: 40).applying(t), tR), "a small distant face still aligns (right)")

// MARK: - Rotation is undone

// Head tilted 30 degrees: the eye line is no longer horizontal.
let angle: CGFloat = .pi / 6
let centre = CGPoint(x: 300, y: 300)
let half: CGFloat = 50
let rotL = CGPoint(x: centre.x - half * cos(angle), y: centre.y - half * sin(angle))
let rotR = CGPoint(x: centre.x + half * cos(angle), y: centre.y + half * sin(angle))
t = FaceAlignment.transform(leftEye: rotL, rightEye: rotR)
expect(near(rotL.applying(t), tL), "a tilted face's left eye is rotated onto the template")
expect(near(rotR.applying(t), tR), "a tilted face's right eye is rotated onto the template")

// Tilted the other way too - a sign error in the rotation passes one of
// these and fails the other.
let negL = CGPoint(x: centre.x - half * cos(angle), y: centre.y + half * sin(angle))
let negR = CGPoint(x: centre.x + half * cos(angle), y: centre.y - half * sin(angle))
t = FaceAlignment.transform(leftEye: negL, rightEye: negR)
expect(near(negL.applying(t), tL), "a face tilted the other way aligns too (left)")
expect(near(negR.applying(t), tR), "a face tilted the other way aligns too (right)")

// MARK: - Scale invariance

// The same face at two sizes produces the same aligned geometry: a point at
// a fixed fraction of the inter-eye distance maps to the same place.
func probePoint(scale: CGFloat) -> CGPoint {
    let l = CGPoint(x: 0, y: 0)
    let r = CGPoint(x: 100 * scale, y: 0)
    let tt = FaceAlignment.transform(leftEye: l, rightEye: r)
    // A point one inter-eye distance below the left eye.
    return CGPoint(x: 0, y: 100 * scale).applying(tt)
}
expect(near(probePoint(scale: 1), probePoint(scale: 3)),
       "alignment is scale invariant")

// And the chin stays below the eyes - the transform must not flip the image.
expect(probePoint(scale: 1).y > tL.y,
       "a point below the eyes stays below them (no vertical flip)")

// MARK: - Degenerate input is refused, not divided by zero

t = FaceAlignment.transform(leftEye: CGPoint(x: 50, y: 50),
                            rightEye: CGPoint(x: 50, y: 50))
expect(t == .identity, "coincident eyes yield identity rather than infinities")

// MARK: - The template sits inside the output

expect(tL.x > 0 && tL.x < FaceAlignment.outputSize, "template left eye is in frame (x)")
expect(tL.y > 0 && tL.y < FaceAlignment.outputSize, "template left eye is in frame (y)")
expect(tR.x > tL.x, "the right eye is to the right of the left eye")
expect(abs(tR.y - tL.y) < 1, "the template eye line is level")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

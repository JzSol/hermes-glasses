//
// FaceAlignment.swift
//
// Maps a detected face onto the canonical 112x112 crop an ArcFace-class
// recogniser expects. Alignment is not a refinement here: these models are
// trained on aligned crops, and feeding one a raw bounding-box crop is the
// usual reason an off-the-shelf face model badly underperforms its
// published numbers.
//
// The transform is a two-point similarity fit on the EYES - rotate so the
// eye line is level, scale so the inter-eye distance matches the template,
// translate so the eyes land on the template points. Five-point Umeyama
// (eyes, nose, mouth corners) is marginally more accurate but needs a
// matrix decomposition and is far harder to verify; the eye pair is a
// genuine similarity transform and is pinned by tests/face-align/.
//
// Both sides of the system call this: portraits at import time and the live
// face crop at snap time. There is exactly ONE implementation and no
// parameters, because two implementations that drift apart make every
// similarity score in the app meaningless while nothing visibly breaks -
// no crash, no log, faces simply stop matching.
//
// Coordinates are the app-wide convention: image pixels, TOP-LEFT origin.
// The one place that differs is CGContext, which is bottom-left; the flip
// happens there (FaceEmbedder.render), not here.
//
// Template constants are the ArcFace 112x112 five-point template's eye
// entries - see tools/export-face.md.
//

import Foundation
import CoreGraphics

enum FaceAlignment {
    /// The recogniser's input edge, in pixels.
    static let outputSize: CGFloat = 112

    /// ArcFace's canonical eye positions in the 112x112 frame.
    static let templateLeftEye = CGPoint(x: 38.2946, y: 51.6963)
    static let templateRightEye = CGPoint(x: 73.5318, y: 51.5014)

    /// Source-image pixel coordinates (top-left origin) to the aligned
    /// 112x112 frame. `leftEye`/`rightEye` are the eyes as they appear in
    /// the image, left-most first.
    ///
    /// Returns `.identity` for coincident eyes rather than dividing by
    /// zero. The caller treats an unusable face as "no embedding", which is
    /// a person who cannot be matched - not a crash mid-conversation.
    static func transform(leftEye: CGPoint, rightEye: CGPoint) -> CGAffineTransform {
        let dx = rightEye.x - leftEye.x
        let dy = rightEye.y - leftEye.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > .ulpOfOne else { return .identity }

        let templateDX = templateRightEye.x - templateLeftEye.x
        let templateDY = templateRightEye.y - templateLeftEye.y
        let templateDistance = (templateDX * templateDX + templateDY * templateDY)
            .squareRoot()

        let scale = templateDistance / distance
        let rotation = atan2(templateDY, templateDX) - atan2(dy, dx)

        // Rotate and scale about the source eye midpoint, then move that
        // midpoint onto the template's. Read the composition right to left:
        // the source midpoint goes to the origin first.
        let sourceMid = CGPoint(x: (leftEye.x + rightEye.x) / 2,
                                y: (leftEye.y + rightEye.y) / 2)
        let templateMid = CGPoint(x: (templateLeftEye.x + templateRightEye.x) / 2,
                                  y: (templateLeftEye.y + templateRightEye.y) / 2)

        return CGAffineTransform.identity
            .translatedBy(x: templateMid.x, y: templateMid.y)
            .rotated(by: rotation)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -sourceMid.x, y: -sourceMid.y)
    }
}

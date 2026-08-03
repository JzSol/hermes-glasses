//
// BadgeCrop.swift
//
// The geometry between "the detector saw a badge" and "Vision has enough
// pixels to read it": flip Vision's origin, drop weak detections, pick one
// box, pad it, and turn it into a pixel rect.
//
// Pure CoreGraphics so tests/badge-crop compiles it with plain swiftc, and
// so the one coordinate-system conversion in this feature lives in a file
// you can read in a minute.
//
// The magnifier is deliberately BadgeRegion's. Those constants were
// measured with tools/ocr-probe.swift against real crop sizes; a detected
// badge needs the same pixels a guessed band did, so there is one number
// to maintain, not two.
//

import CoreGraphics

/// A badge the detector found, in unit coordinates of the person crop
/// (origin TOP-LEFT, matching `Detection.rect`). `label` is the model's raw
/// class string - mapping it to `Badge.Kind` is the reader's job, which
/// keeps this file free of the persistence model.
struct BadgeBox: Equatable {
    var label: String
    var confidence: Float
    var rect: CGRect
}

enum BadgeCrop {
    /// Below this, a "badge" is usually a phone screen or a shirt pocket.
    /// Higher than ObjectDetector's 0.4 because a false badge sends OCR
    /// somewhere with no text at all, which is worse than falling back to
    /// the band that at least covers the torso.
    static let minimumConfidence: Float = 0.45

    /// Fraction of the box's own size added on each side. A tight box
    /// habitually clips the last printed line - the employer, usually - and
    /// the pad is cheap insurance.
    static let padding: CGFloat = 0.12

    /// Vision observation -> a badge box, or nil when it is too weak to
    /// trust. This is the ONLY place Vision's bottom-left origin is
    /// converted; everything downstream is top-left, like `Detection`.
    static func box(
        label: String, confidence: Float, visionRect: CGRect
    ) -> BadgeBox? {
        guard confidence >= minimumConfidence else { return nil }
        let rect = CGRect(
            x: visionRect.minX, y: 1 - visionRect.maxY,
            width: visionRect.width, height: visionRect.height
        )
        return BadgeBox(label: label, confidence: confidence, rect: rect)
    }

    /// The one box to read. A person can wear two tags - a clinical stack,
    /// a conference badge over a staff ID - and reading the most confident
    /// one is honest, where merging two tags would invent a person who is
    /// half of each.
    static func best(_ boxes: [BadgeBox]) -> BadgeBox? {
        boxes.max { $0.confidence < $1.confidence }
    }

    /// The box grown by `fraction` (of its own size, default `padding`) and
    /// clamped inside the unit square. Callers with a different padding
    /// need (see `BadgePortrait`) pass their own `fraction` rather than
    /// reimplementing this grow-and-clamp.
    static func padded(_ rect: CGRect, by fraction: CGFloat = padding) -> CGRect {
        let grown = rect.insetBy(
            dx: -rect.width * fraction, dy: -rect.height * fraction
        )
        return grown.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A unit rect as integral pixels inside an image of `size`. Nil when
    /// there is nothing croppable - a degenerate box or a zero-sized image.
    ///
    /// The size floor is checked BEFORE `.integral`, not after: `.integral`
    /// snaps to the enclosing integer grid, so a genuinely sub-pixel box
    /// (say 0.02x0.02 px) would round UP to a 1x1 rect and slip past a
    /// post-integral check - inventing a crop that was never really there.
    static func pixelRect(for rect: CGRect, in size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let pixels = CGRect(
            x: rect.minX * size.width, y: rect.minY * size.height,
            width: rect.width * size.width, height: rect.height * size.height
        )
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return pixels.integral
    }

    /// The size to render a badge crop at so its text clears Vision's
    /// practical floor. Delegates to the measured constants.
    static func upscaledSize(for size: CGSize) -> CGSize {
        BadgeRegion.upscaledSize(for: size)
    }
}

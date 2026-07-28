//
// BadgeRegion.swift
//
// Where on a person a name badge is, and how much to magnify it before
// asking Vision to read it.
//
// This exists because OCR over the whole person crop returns nothing. A
// lanyard's name line is under 1% of a head-to-knees crop's height, and at
// the resolution the glasses actually stream (.low - see
// HermesCameraManager.startLiveStream) that is a handful of pixels. It is
// NOT a VNRecognizeTextRequest.minimumTextHeight problem: lowering that
// threshold changes nothing, because the text never had enough pixels to
// recognise. Measured in tools/ocr-probe.swift; re-run it before arguing
// with these numbers.
//
// Pure CoreGraphics so tests/badge-region compiles it with plain swiftc.
//

import CoreGraphics

enum BadgeRegion {
    /// Fraction of the person crop's height where a lanyard hangs. A badge
    /// on a neck cord sits around mid-chest; the band is generous at both
    /// ends because the person box is only as tight as YOLO drew it and the
    /// snap adds 25% padding on top.
    static let bandTop: CGFloat = 0.22
    static let bandBottom: CGFloat = 0.72

    /// Horizontal inset. Badges are worn near the body's midline, but clip-on
    /// tags ride out towards a shoulder, so this trims very little.
    static let horizontalInset: CGFloat = 0.08

    /// Vision needs real pixels, not a big rectangle. Below this on the short
    /// side, the band is upscaled before recognition.
    static let minimumShortSide: CGFloat = 1000

    /// Never magnify past this - beyond it interpolation is inventing detail
    /// and only costs time.
    static let maximumUpscale: CGFloat = 8

    /// The lanyard band inside a person crop, in unit coordinates of that
    /// crop (origin top-left, same convention as `Detection.rect`).
    static var band: CGRect {
        CGRect(
            x: horizontalInset,
            y: bandTop,
            width: 1 - horizontalInset * 2,
            height: bandBottom - bandTop
        )
    }

    /// How much to magnify a band of this pixel size so its text clears
    /// Vision's practical floor. Always >= 1: shrinking a crop that is
    /// already large would throw away the pixels we came for.
    static func upscaleFactor(forShortSide shortSide: CGFloat) -> CGFloat {
        guard shortSide > 0 else { return 1 }
        guard shortSide < minimumShortSide else { return 1 }
        return min(maximumUpscale, minimumShortSide / shortSide)
    }

    /// Pixel size to render a band of `size` at, after magnification.
    static func upscaledSize(for size: CGSize) -> CGSize {
        let factor = upscaleFactor(forShortSide: min(size.width, size.height))
        guard factor > 1 else { return size }
        return CGSize(
            width: (size.width * factor).rounded(),
            height: (size.height * factor).rounded()
        )
    }
}

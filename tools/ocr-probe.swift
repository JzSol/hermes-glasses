// ocr-probe.swift
//
// Measures whether a lanyard badge inside a person crop is readable by
// Vision, at the crop sizes the app actually produces. This is the evidence
// behind BadgeRegion - re-run it before changing those constants or
// re-arguing why the whole-person crop returns nothing.
//
// It renders a synthetic person crop (torso block, white badge card, name +
// employer at a realistic scale) and runs Vision three ways:
//   A. the pre-2026-07-27 BadgeReader - one pass over the whole crop
//   B. the same, with minimumTextHeight lowered (the disproved hypothesis)
//   C. what ships now - BadgeRegion's magnified band, then the whole crop
//
// macOS only (AppKit for text rendering); BadgeRegion itself is pure
// CoreGraphics and is compiled in so the probe tests the real geometry:
//
//   xcrun swiftc HermesGlasses/Services/Social/BadgeRegion.swift \
//     tools/ocr-probe.swift -o /tmp/ocr-probe && /tmp/ocr-probe

import AppKit
import Foundation
import Vision

func makePersonCrop(width: Int, height: Int, badgeTextPoints: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    ctx.setFillColor(CGColor(red: 0.20, green: 0.22, blue: 0.24, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0.80, green: 0.82, blue: 0.74, alpha: 1))
    ctx.fill(CGRect(x: Double(width) * 0.15, y: Double(height) * 0.25,
                    width: Double(width) * 0.70, height: Double(height) * 0.50))

    // The badge card, in the upper-torso band where a lanyard hangs.
    let badgeW = Double(width) * 0.26
    let badgeH = badgeW * 0.62
    let badgeX = Double(width) * 0.40
    let badgeY = Double(height) * 0.46
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSString(string: "Priya Raman").draw(
        at: NSPoint(x: badgeX + badgeW * 0.06, y: badgeY + badgeH * 0.52),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: badgeTextPoints, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
    NSString(string: "Penn Medicine").draw(
        at: NSPoint(x: badgeX + badgeW * 0.06, y: badgeY + badgeH * 0.16),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: badgeTextPoints * 0.72),
            .foregroundColor: NSColor.black,
        ])
    NSGraphicsContext.restoreGraphicsState()

    return ctx.makeImage()!
}

/// Mirrors BadgeReader.recognize.
func recognize(_ image: CGImage, minimumTextHeight: Float? = nil) -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    if let minimumTextHeight { request.minimumTextHeight = minimumTextHeight }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return ["<error: \(error)>"] }
    return (request.results ?? [])
        .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        .compactMap { obs in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.4
            else { return nil }
            return c.string
        }
}

/// Mirrors BadgeReader.magnifiedBand, using the shipped BadgeRegion values.
func magnifiedBand(of image: CGImage) -> CGImage? {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let band = BadgeRegion.band
    let px = CGRect(x: band.minX * w, y: band.minY * h,
                    width: band.width * w, height: band.height * h).integral
    guard px.width >= 1, px.height >= 1,
          let cropped = image.cropping(to: px) else { return nil }

    let target = BadgeRegion.upscaledSize(
        for: CGSize(width: px.width, height: px.height))
    guard target.width > px.width else { return cropped }

    let ctx = CGContext(
        data: nil, width: Int(target.width), height: Int(target.height),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(origin: .zero, size: target))
    return ctx.makeImage()
}

/// Mirrors BadgeReader.readLines: band pass first, then the whole crop.
func readLines(from image: CGImage) -> [String] {
    var lines: [String] = []
    var seen = Set<String>()
    for candidate in [magnifiedBand(of: image), image] {
        guard let candidate else { continue }
        for line in recognize(candidate) where seen.insert(line.lowercased()).inserted {
            lines.append(line)
        }
    }
    return lines
}

// `@main` rather than top-level code: this probe is compiled together with
// BadgeRegion.swift, and Swift only allows statements at the top level in a
// file literally named main.swift.
@main
enum Probe {
    static func main() {
        // The person box a `.low` glasses stream yields, and a mid-res phone
        // frame.
        for (label, w, h, pts) in [
            ("full-body crop, low-res", 320, 600, 5.0),
            ("full-body crop, mid-res", 640, 1200, 10.0),
        ] {
            let img = makePersonCrop(width: w, height: h, badgeTextPoints: pts)
            let fraction = String(format: "%.3f", Double(pts) / Double(h))
            print("\n=== \(label) (\(w)x\(h), badge text ~\(fraction) of height) ===")
            print("  A. one pass, whole crop (old)      -> \(recognize(img))")
            print("  B. + minimumTextHeight = 0.008     -> \(recognize(img, minimumTextHeight: 0.008))")
            print("  C. band + upscale, then crop (new) -> \(readLines(from: img))")
        }
    }
}

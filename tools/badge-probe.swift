// badge-probe.swift
//
// Answers the only question that decides whether badge11n ships: does
// locating the badge read more names than BadgeRegion's guessed band? mAP
// is not the metric here - "did the name come out" is (see
// tools/train-badge.md). This is the gate, not a benchmark.
//
// Point it at a directory of person crops (JPEG/PNG, as the app produces
// them - see EncounterStore's photos/ directory, which you can pull off
// the device with the Files app). For each it prints one row:
//
//   A. the band path      - BadgeRegion's magnified band, then OCR
//   B. the detected path  - badge11n's box, padded and magnified, then OCR
//
// With no model argument, only column A runs - that is still the baseline
// you need, and it is the mode that works today, with no model bundled.
//
// macOS only (AppKit for the synthetic self-test's text rendering).
// BadgeRegion and BadgeCrop are compiled in, so the probe measures the
// real geometry the app ships, not a re-implementation of it:
//
//   xcrun swiftc HermesGlasses/Services/Social/BadgeRegion.swift \
//     HermesGlasses/Services/Social/BadgeCrop.swift \
//     tools/badge-probe.swift -o /tmp/badge-probe \
//     && /tmp/badge-probe ~/Desktop/person-crops
//
// The model path needs a compiled badge11n.mlmodelc. Compile the package
// and pass ITS OUTPUT DIRECTORY as the second argument (the probe looks
// for badge11n.mlmodelc inside it, matching BadgeDetector.modelName):
//
//   xcrun coremlcompiler compile HermesGlasses/Models/badge11n.mlpackage /tmp
//   /tmp/badge-probe ~/Desktop/person-crops /tmp
//
// With no arguments at all, the probe runs a synthetic self-test (the
// makePersonCrop approach from tools/ocr-probe.swift) so it proves itself
// runnable with no photographs and no model - that mode is a smoke test,
// not evidence for or against a real model.

import AppKit
import CoreML
import Foundation
import Vision

// MARK: - Synthetic crops (self-test only, no assets required)

/// Renders a synthetic person crop (torso block, white badge card, name +
/// employer at a realistic scale). Mirrors tools/ocr-probe.swift's
/// makePersonCrop so the self-test exercises the same shape of image.
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

// MARK: - Shared Vision pass

/// One OCR pass. Mirrors BadgeReader's `recognize`: `.accurate`,
/// `usesLanguageCorrection = false` (correction mangles surnames - that is
/// why the shipping code disables it), sorted top-of-badge first, filtered
/// at the same confidence floor.
func recognizeText(_ image: CGImage) -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return [] }
    return (request.results ?? [])
        .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        .compactMap { obs in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.4
            else { return nil }
            return c.string
        }
}

/// Upscale a crop to `target`, matching BadgeRegion/BadgeCrop's shared
/// upscaledSize. Returns the input unchanged when it is already big enough.
func upscale(_ image: CGImage, to target: CGSize) -> CGImage {
    guard target.width > CGFloat(image.width) else { return image }
    let ctx = CGContext(
        data: nil, width: Int(target.width), height: Int(target.height),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(origin: .zero, size: target))
    return ctx.makeImage() ?? image
}

// MARK: - A. The band path (BadgeRegion, real geometry)

/// Mirrors BadgeReader's magnifiedBand + recognize: crop BadgeRegion.band,
/// upscale via BadgeRegion.upscaledSize, then OCR. This is the baseline -
/// what ships with no model bundled, today.
func bandLines(from image: CGImage) -> [String] {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    guard w > 0, h > 0 else { return [] }
    let band = BadgeRegion.band
    let pixelRect = CGRect(
        x: band.minX * w, y: band.minY * h,
        width: band.width * w, height: band.height * h
    ).integral
    guard pixelRect.width >= 1, pixelRect.height >= 1,
          let cropped = image.cropping(to: pixelRect)
    else { return [] }
    let target = BadgeRegion.upscaledSize(
        for: CGSize(width: pixelRect.width, height: pixelRect.height))
    return recognizeText(upscale(cropped, to: target))
}

// MARK: - B. The detected path (badge11n + BadgeCrop, real geometry)

/// Load a compiled badge11n.mlmodelc from a directory - the output of
/// `xcrun coremlcompiler compile badge11n.mlpackage <dir>`. Returns nil
/// (with a message on stderr) when there is nothing usable there, which
/// the caller treats the same as "no model argument given".
func loadDetector(fromDirectory directory: String) -> VNCoreMLModel? {
    let modelName = "badge11n" // must match BadgeDetector.modelName
    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(modelName).mlmodelc")
    guard FileManager.default.fileExists(atPath: url.path) else {
        FileHandle.standardError.write(
            "no \(modelName).mlmodelc found in \(directory) - run xcrun coremlcompiler first\n"
                .data(using: .utf8)!)
        return nil
    }
    do {
        let config = MLModelConfiguration()
        let mlModel = try MLModel(contentsOf: url, configuration: config)
        return try VNCoreMLModel(for: mlModel)
    } catch {
        FileHandle.standardError.write("failed to load \(url.path): \(error)\n".data(using: .utf8)!)
        return nil
    }
}

/// Mirrors BadgeDetector.detect + BadgeCrop.box/.best: run the model, turn
/// observations into BadgeBoxes (top-left origin, confidence-gated), keep
/// the single most confident one.
func detectBadgeBox(in image: CGImage, model: VNCoreMLModel) -> BadgeBox? {
    let request = VNCoreMLRequest(model: model)
    request.imageCropAndScaleOption = .scaleFill
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return nil }
    let observations = request.results as? [VNRecognizedObjectObservation] ?? []
    let boxes = observations.compactMap { observation -> BadgeBox? in
        guard let top = observation.labels.first else { return nil }
        return BadgeCrop.box(
            label: top.identifier, confidence: observation.confidence,
            visionRect: observation.boundingBox)
    }
    return BadgeCrop.best(boxes)
}

/// Mirrors BadgeReader's detected path: locate, pad via BadgeCrop.padded,
/// crop to pixels via BadgeCrop.pixelRect, upscale via
/// BadgeCrop.upscaledSize, then OCR.
func detectedLines(from image: CGImage, model: VNCoreMLModel) -> (box: BadgeBox?, lines: [String]) {
    guard let box = detectBadgeBox(in: image, model: model) else { return (nil, []) }
    let padded = BadgeCrop.padded(box.rect)
    let size = CGSize(width: image.width, height: image.height)
    guard let pixelRect = BadgeCrop.pixelRect(for: padded, in: size),
          let cropped = image.cropping(to: pixelRect)
    else { return (box, []) }
    let target = BadgeCrop.upscaledSize(
        for: CGSize(width: cropped.width, height: cropped.height))
    return (box, recognizeText(upscale(cropped, to: target)))
}

// MARK: - Reporting

func quoted(_ line: String?) -> String {
    guard let line, !line.isEmpty else { return "-" }
    return "\"\(line)\""
}

struct Tally {
    var bandOnly = 0
    var detectedOnly = 0
    var both = 0
    var neither = 0

    mutating func record(band: String?, detected: String?) {
        switch (band != nil, detected != nil) {
        case (true, false): bandOnly += 1
        case (false, true): detectedOnly += 1
        case (true, true): both += 1
        case (false, false): neither += 1
        }
    }

    var summary: String {
        """
        \(both) file(s) both paths named, \(bandOnly) only the band named, \
        \(detectedOnly) only detected named, \(neither) neither named.
        Gate: detected must beat the band, i.e. detectedOnly > bandOnly, \
        before badge11n ships.
        """
    }
}

func printRow(name: String, band: String?, detected: String??) {
    let bandCol = "band: \(quoted(band))"
    guard let detected else {
        print("  \(name.padding(toLength: max(name.count, 28), withPad: " ", startingAt: 0)) \(bandCol)")
        return
    }
    let detectedCol = "detected: \(quoted(detected))"
    print("  \(name.padding(toLength: max(name.count, 28), withPad: " ", startingAt: 0)) \(bandCol.padding(toLength: max(bandCol.count, 26), withPad: " ", startingAt: 0)) \(detectedCol)")
}

// MARK: - Modes

func loadCGImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func runSelfTest() {
    print("No arguments given - running the synthetic self-test (no photos, no model needed).")
    print("This proves the probe runs; it is not evidence for or against a real model.\n")

    let crops: [(label: String, w: Int, h: Int, pts: CGFloat)] = [
        ("synthetic-low-res.png (320x600, glasses .low scale)", 320, 600, 5.0),
        ("synthetic-mid-res.png (640x1200, phone-photo scale)", 640, 1200, 10.0),
    ]

    var tally = Tally()
    for crop in crops {
        let image = makePersonCrop(width: crop.w, height: crop.h, badgeTextPoints: crop.pts)
        let band = bandLines(from: image).first
        printRow(name: crop.label, band: band, detected: nil)
        tally.record(band: band, detected: nil)
    }
    print("\nNo model argument given - the detected column needs a compiled badge11n.mlmodelc.")
    print("Self-test band results: \(tally.both + tally.bandOnly)/\(crops.count) crops named via the band path.")
}

func runDirectory(path: String, modelDirectory: String?) {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        print("error: \(path) is not a directory")
        exit(1)
    }
    guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
        print("error: could not read \(path)")
        exit(1)
    }
    let files = entries
        .filter { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }
        .sorted()
    guard !files.isEmpty else {
        print("error: no JPEG/PNG files found in \(path)")
        exit(1)
    }

    let model = modelDirectory.flatMap(loadDetector)
    if let modelDirectory, model == nil {
        print("warning: could not load a model from \(modelDirectory) - continuing with the band column only.\n")
    } else if model == nil {
        print("No model argument given - printing the band column only.")
        print("The detected column needs a compiled badge11n.mlmodelc (see this file's header).\n")
    }

    var tally = Tally()
    for file in files {
        let url = URL(fileURLWithPath: path).appendingPathComponent(file)
        guard let image = loadCGImage(at: url) else {
            print("  \(file): could not decode image, skipping")
            continue
        }
        let band = bandLines(from: image).first
        if let model {
            let detected = detectedLines(from: image, model: model).lines.first
            printRow(name: file, band: band, detected: .some(detected))
            tally.record(band: band, detected: detected)
        } else {
            printRow(name: file, band: band, detected: nil)
            tally.record(band: band, detected: nil)
        }
    }

    print("")
    if model != nil {
        print(tally.summary)
    } else {
        print("\(tally.both + tally.bandOnly) of \(files.count) file(s) named via the band path.")
        print("Re-run with a compiled model directory as argv[2] to measure the detected path.")
    }
}

// `@main` rather than top-level code: this probe is compiled together with
// BadgeRegion.swift and BadgeCrop.swift, and Swift only allows statements
// at the top level in a file literally named main.swift.
@main
enum BadgeProbe {
    static func main() {
        let args = CommandLine.arguments
        switch args.count {
        case 1:
            runSelfTest()
        case 2:
            runDirectory(path: args[1], modelDirectory: nil)
        default:
            runDirectory(path: args[1], modelDirectory: args[2])
        }
    }
}

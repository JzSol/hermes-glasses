// face-probe.swift
//
// Measures the roster before the app trusts it. The question this answers
// is not "is the model good" but "can these photos identify these people at
// all" - and the two are independent. A portrait with no findable face is a
// person who can never be recognised no matter how good the recogniser is,
// and that has to be known before the conference rather than during it.
//
// Modes (only `coverage` runs without a bundled face model):
//
//   coverage <folder>   - Vision face detection over every image. How many
//                         faces, how large, how frontal, and which files
//                         have none. This is the pre-flight.
//
// Modes `separation` and `live` land with the model - see
// tools/export-face.md and the implementation plan.
//
// macOS only (Vision + AppKit for image loading). The real FaceAlignment,
// FaceEmbedding and FaceMatcher are compiled in, so the probe measures the
// code that ships rather than a re-implementation of it:
//
//   xcrun swiftc -parse-as-library -O \
//     HermesGlasses/Services/People/FaceAlignment.swift \
//     HermesGlasses/Services/People/FaceEmbedding.swift \
//     HermesGlasses/Services/People/RosterPerson.swift \
//     HermesGlasses/Services/People/FaceMatcher.swift \
//     tools/face-probe.swift -o /tmp/face-probe \
//     && /tmp/face-probe separation ~/Downloads/ice2026-people
//

import Foundation
import Vision
import AppKit
import CoreImage

func loadCGImage(_ url: URL) -> CGImage? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

struct Coverage {
    let file: String
    let faces: Int
    /// Largest face's width as a fraction of image width.
    let largestWidth: Double
    /// Yaw in radians, nil when Vision did not report one.
    let yaw: Double?
    /// Did Vision find eye landmarks? Alignment needs them, and a face
    /// rectangle with no landmarks is still unusable for recognition.
    let hasEyes: Bool
}

func coverage(of url: URL) -> Coverage? {
    guard let cg = loadCGImage(url) else { return nil }
    let request = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([request]) } catch { return nil }
    let faces = request.results ?? []
    let largest = faces.max {
        $0.boundingBox.width * $0.boundingBox.height
            < $1.boundingBox.width * $1.boundingBox.height
    }
    let eyes = largest?.landmarks?.leftEye != nil
        && largest?.landmarks?.rightEye != nil
    return Coverage(
        file: url.lastPathComponent,
        faces: faces.count,
        largestWidth: largest.map { Double($0.boundingBox.width) } ?? 0,
        yaw: largest?.yaw?.doubleValue,
        hasEyes: eyes
    )
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text
        : text + String(repeating: " ", count: width - text.count)
}

// MARK: - separation

/// Does the embedder tell these 45 people apart at all? Embeds every
/// portrait through the REAL shared core (FaceEmbedding, compiled in) and
/// reports the inter-person similarity distribution plus the closest
/// confusable pairs.
///
/// With one photo per person there are no intra-person pairs, so this can
/// only measure how far apart DIFFERENT people sit. That is a ceiling, not
/// a guarantee: the same person photographed twice must sit closer than the
/// closest two strangers, and nothing here proves they do.
func separation(folder: URL, files: [URL]) -> Int {
    var names: [String] = []
    var vectors: [[Float]] = []
    var failed: [String] = []

    for url in files {
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        guard let cg = loadCGImage(url),
              let vector = FaceEmbedding.embed(cg, backend: .visionFeaturePrint)
        else { failed.append(name); continue }
        names.append(name)
        vectors.append(vector)
    }

    guard vectors.count >= 2 else {
        print("Not enough embeddable portraits (\(vectors.count)).")
        return 2
    }
    print("Embedded \(vectors.count) of \(files.count) portraits "
          + "(\(vectors.first?.count ?? 0)-d, Vision feature print on the aligned crop).")
    if !failed.isEmpty { print("Failed: \(failed.joined(separator: ", "))") }

    var pairs: [(a: String, b: String, score: Float)] = []
    for i in 0..<vectors.count {
        for j in (i + 1)..<vectors.count {
            pairs.append((names[i], names[j],
                          FaceMatcher.cosine(vectors[i], vectors[j])))
        }
    }
    pairs.sort { $0.score > $1.score }

    let scores = pairs.map(\.score).sorted()
    func percentile(_ p: Double) -> Float {
        let idx = min(scores.count - 1, max(0, Int(p * Double(scores.count - 1))))
        return scores[idx]
    }

    print("\nINTER-PERSON similarity over \(pairs.count) pairs "
          + "(these are all DIFFERENT people - every one of these is a"
          + " potential false match):")
    print(String(format: "  min    %.4f", scores.first ?? 0))
    print(String(format: "  p50    %.4f", percentile(0.50)))
    print(String(format: "  p90    %.4f", percentile(0.90)))
    print(String(format: "  p99    %.4f", percentile(0.99)))
    print(String(format: "  MAX    %.4f", scores.last ?? 0))

    print("\nCLOSEST PAIRS - the ones most likely to be confused for each other:")
    for pair in pairs.prefix(10) {
        print(String(format: "  %.4f  %@  <->  %@", pair.score, pair.a, pair.b))
    }

    let maxInter = scores.last ?? 0
    print("""

    READ THIS BEFORE TRUSTING ANY NUMBER ABOVE
    ------------------------------------------
    A usable recogniser needs SAME-person pairs to score clearly above the
    MAX inter-person score printed here. This roster has one photo each, so
    that half cannot be measured - run `live` with device crops of people
    who ARE in the roster to get it.

    Until then the only safe reading is the negative one: if the max
    inter-person score is high (say above ~0.85), strangers already look
    alike to this embedder and no threshold can separate them.
    """)
    print(String(format: "\n  max inter-person = %.4f", maxInter))
    if maxInter > 0.85 {
        print("  VERDICT: too high. This embedder cannot be trusted to name people.")
    } else {
        print("  VERDICT: strangers are separable here; same-person spread is still unmeasured.")
    }
    return 0
}

// MARK: - simulate

/// The question `separation` cannot answer with one photo per person: does
/// the SAME person still match themselves once the image looks like what
/// the glasses actually deliver?
///
/// Each portrait is degraded in ways the live path really imposes - dropped
/// to glasses-stream resolution, softened, tilted, re-exposed - and scored
/// against its own original. Those are same-person pairs, synthesised but
/// honest about the failure mode that matters.
///
/// The bar: same-person scores must sit clearly ABOVE the worst
/// inter-person score, or no threshold can separate a match from a
/// stranger.
func simulate(files: [URL], maxInterPerson: Float) -> Int {
    let ctx = CIContext()

    /// Re-render at `width` px wide and back up - the resolution cliff.
    func downscaled(_ image: CGImage, to width: Int) -> CGImage? {
        let scale = CGFloat(width) / CGFloat(image.width)
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let small = CGContext(
            data: nil, width: width, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: width, height: h))
        return small.makeImage()
    }

    func filtered(_ image: CGImage, _ transform: (CIImage) -> CIImage) -> CGImage? {
        let out = transform(CIImage(cgImage: image))
        return ctx.createCGImage(out, from: out.extent)
    }

    func rotated(_ image: CGImage, degrees: CGFloat) -> CGImage? {
        filtered(image) {
            $0.transformed(by: CGAffineTransform(rotationAngle: degrees * .pi / 180))
        }
    }

    // `decisive` marks the variants that reflect what the glasses actually
    // deliver. The others are sanity checks: passing them proves the
    // pipeline runs, NOT that the embedder can identify anyone, and the
    // verdict must never be computed from them - a headline of "some
    // variants separate" carried by a barely-altered image is exactly the
    // flattering summary this tool exists to prevent.
    let variants: [(name: String, decisive: Bool, make: (CGImage) -> CGImage?)] = [
        ("glasses-res 96px", true, { downscaled($0, to: 96) }),
        ("glasses-res 64px", true, { downscaled($0, to: 64) }),
        ("soft focus", true, { img in
            filtered(img) {
                $0.applyingGaussianBlur(sigma: 2.0).cropped(to: $0.extent)
            }
        }),
        ("tilt 10 deg", true, { rotated($0, degrees: 10) }),
        ("under-exposed", false, { img in
            filtered(img) {
                $0.applyingFilter("CIExposureAdjust", parameters: ["inputEV": -1.2])
            }
        }),
    ]

    var byVariant: [String: [Float]] = [:]
    var embeddedOriginals = 0
    var variantFailures: [String: Int] = [:]

    for url in files {
        guard let cg = loadCGImage(url),
              let base = FaceEmbedding.embed(cg, backend: .visionFeaturePrint)
        else { continue }
        embeddedOriginals += 1
        for variant in variants {
            guard let degraded = variant.make(cg),
                  let vector = FaceEmbedding.embed(degraded, backend: .visionFeaturePrint)
            else {
                variantFailures[variant.name, default: 0] += 1
                continue
            }
            byVariant[variant.name, default: []].append(
                FaceMatcher.cosine(base, vector)
            )
        }
    }

    guard embeddedOriginals > 0 else {
        print("No portraits embedded.")
        return 2
    }

    print("SAME-PERSON similarity after realistic degradation "
          + "(\(embeddedOriginals) portraits).")
    print(String(format: "Worst-case stranger pair scored %.4f - every number"
                 + " below must beat that.\n", maxInterPerson))
    print(pad("variant", 20) + pad("min", 9) + pad("p10", 9)
          + pad("median", 9) + pad("lost face", 10) + "beats strangers?")

    var decisiveFailures = 0
    var decisiveTotal = 0
    for variant in variants {
        let scores = (byVariant[variant.name] ?? []).sorted()
        guard !scores.isEmpty else {
            print(pad(variant.name, 20) + "no face survived")
            if variant.decisive { decisiveTotal += 1; decisiveFailures += 1 }
            continue
        }
        let p10 = scores[min(scores.count - 1, Int(0.10 * Double(scores.count)))]
        let median = scores[scores.count / 2]
        // The honest test: the WEAK end of same-person has to clear the
        // STRONG end of stranger. Comparing medians would flatter it.
        let usable = p10 > maxInterPerson
        if variant.decisive {
            decisiveTotal += 1
            if !usable { decisiveFailures += 1 }
        }
        print(pad(variant.name, 20)
              + pad(String(format: "%.4f", scores.first ?? 0), 9)
              + pad(String(format: "%.4f", p10), 9)
              + pad(String(format: "%.4f", median), 9)
              + pad("\(variantFailures[variant.name] ?? 0)", 10)
              + (usable ? "yes" : "NO")
              + (variant.decisive ? "" : "   (sanity check only)"))
    }

    print("""

    WHAT THIS MEANS
    ---------------
    "beats strangers" = the 10th-percentile same-person score is still above
    the closest stranger pair. Anything less and there is no threshold that
    admits the right person while rejecting the wrong one - the two
    distributions overlap, and the app would name people confidently and
    wrongly.
    """)
    print("\n  \(decisiveTotal - decisiveFailures)/\(decisiveTotal) decisive"
          + " variants separate (sanity checks excluded).")
    if decisiveFailures == 0 {
        print("  VERDICT: this embedder survives realistic degradation."
              + " Confirm with real device crops before trusting it.")
        return 0
    }
    print("""
      VERDICT: FAILS. At the resolution the glasses actually deliver, the
      same person scores FURTHER from themselves than two different people
      score from each other. No threshold can separate those distributions,
      so an app using this embedder would name people confidently and
      wrongly. Do not ship it.
    """)
    return 1
}

// MARK: - main

// Top-level statements are only legal in a file named main.swift, and this
// probe is compiled alongside the real FaceAlignment / FaceEmbedding /
// FaceMatcher sources - so the entry point is @main and the build line
// needs -parse-as-library.
@main
struct FaceProbe {
    static func main() {

        let args = CommandLine.arguments
        let modes = ["coverage", "separation", "simulate"]
        guard args.count >= 3, modes.contains(args[1]) else {
            print("usage: face-probe <coverage|separation|simulate> <folder>")
            exit(2)
        }

        let folder = URL(fileURLWithPath: args[2])
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic"]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else {
            print("No images found in \(folder.path)")
            exit(2)
        }

        if args[1] == "separation" {
            exit(Int32(separation(folder: folder, files: files)))
        }
        if args[1] == "simulate" {
            // The stranger ceiling measured by `separation` on this roster.
            exit(Int32(simulate(files: files, maxInterPerson: 0.8657)))
        }

        var noFace: [String] = []
        var noEyes: [String] = []
        var multiFace: [String] = []
        var smallFace: [String] = []

        print(pad("file", 42) + pad("faces", 7) + pad("width", 8) + "yaw")
        for url in files {
            guard let c = coverage(of: url) else {
                print(pad(url.lastPathComponent, 42) + "UNREADABLE")
                noFace.append(url.lastPathComponent)
                continue
            }
            let yawText = c.yaw.map { String(format: "%+.2f", $0) } ?? "  -"
            print(pad(c.file, 42)
                  + pad("\(c.faces)", 7)
                  + pad(String(format: "%.3f", c.largestWidth), 8)
                  + yawText
                  + (c.faces > 0 && !c.hasEyes ? "   NO EYES" : ""))
            if c.faces == 0 { noFace.append(c.file) }
            if c.faces > 0 && !c.hasEyes { noEyes.append(c.file) }
            if c.faces > 1 { multiFace.append(c.file) }
            // A portrait whose face is under a third of the frame is mostly
            // background, which costs alignment accuracy.
            if c.faces > 0 && c.largestWidth < 0.33 { smallFace.append(c.file) }
        }

        print("\n\(files.count) images, \(files.count - noFace.count) with a findable face.")
        if !noFace.isEmpty {
            print("\nNO FACE (\(noFace.count)) - these people can never be recognised:")
            noFace.forEach { print("  \($0)") }
        }
        if !noEyes.isEmpty {
            print("\nNO EYE LANDMARKS (\(noEyes.count)) - a face was found but cannot be aligned:")
            noEyes.forEach { print("  \($0)") }
        }
        if !multiFace.isEmpty {
            print("\nMORE THAN ONE FACE (\(multiFace.count)) - the largest is assumed to be the subject:")
            multiFace.forEach { print("  \($0)") }
        }
        if !smallFace.isEmpty {
            print("\nSMALL FACE (\(smallFace.count)) - under a third of frame width, alignment will be coarse:")
            smallFace.forEach { print("  \($0)") }
        }
        exit(noFace.isEmpty && noEyes.isEmpty ? 0 : 1)
    }
}

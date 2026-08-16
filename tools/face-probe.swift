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
// macOS only (Vision + AppKit for image loading):
//
//   xcrun swiftc tools/face-probe.swift -o /tmp/face-probe \
//     && /tmp/face-probe coverage ~/Downloads/ice2026-people
//

import Foundation
import Vision
import AppKit

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

let args = CommandLine.arguments
guard args.count >= 3, args[1] == "coverage" else {
    print("usage: face-probe coverage <folder>")
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

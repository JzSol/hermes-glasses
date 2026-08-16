//
// FaceEmbedder.swift
//
// Face crop in, L2-normalised vector out, entirely on-device.
//
// The model is OPTIONAL at build time but REQUIRED at runtime: with no
// `faceid.mlpackage` bundled, `FaceEmbedder()` returns nil and Lookup says
// so plainly. There is deliberately no weaker fallback.
//
// That breaks the ladder BadgeDetector/BadgeRegion follows in this codebase,
// and for a reason worth stating: the badge band's failure mode is SILENCE -
// no name read, the wearer tries again - while a weak face matcher's failure
// mode is a confident WRONG name, spoken about someone standing in front of
// you. A floor is worth shipping when its failure is silence, not when its
// failure is a lie.
//
// Pipeline: detect landmarks -> align on the eyes (FaceAlignment, the same
// call import makes) -> normalise -> infer -> L2-normalise.
//

import Foundation
import CoreML
import Vision
import UIKit

struct FaceEmbedder {
    static let modelName = "faceid"

    private let model: MLModel
    private let inputName: String
    /// Stamped onto every embedding it produces, so a model swap is caught
    /// rather than silently compared across - see RosterPerson.modelID.
    let modelID: String

    /// Nil when no model is bundled. Callers must treat that as "this
    /// feature is unavailable", never as "match with something weaker".
    init?() {
        guard let url = Bundle.main.url(
            forResource: Self.modelName, withExtension: "mlmodelc"
        ), let loaded = try? MLModel(contentsOf: url) else {
            NSLog("[Hermes] face: no \(Self.modelName) model bundled")
            return nil
        }
        let description = loaded.modelDescription
        guard let input = description.inputDescriptionsByName.keys.sorted().first else {
            NSLog("[Hermes] face: model has no inputs")
            return nil
        }
        model = loaded
        inputName = input
        // Includes the output count, so swapping in a different-dimension
        // model is caught even when the file name is unchanged.
        modelID = "\(Self.modelName)-in\(Int(FaceAlignment.outputSize))"
            + "-out\(description.outputDescriptionsByName.count)"
    }

    static var isAvailable: Bool { FaceEmbedder() != nil }

    /// Does this image contain a face that could be aligned? Used by the
    /// importer to report coverage before any model exists - a portrait
    /// that fails here can never be recognised, whatever the recogniser.
    static func hasDetectableFace(_ image: UIImage) async -> Bool {
        await eyes(in: image) != nil
    }

    /// Eye centres in image pixel coordinates (top-left origin) for the
    /// largest detected face. Nil when no face is found, or when Vision
    /// finds a face but no eye landmarks - a face that cannot be aligned is
    /// no use to a recogniser trained on aligned crops.
    ///
    /// Detached for the same reason BadgeReader's passes are: the Vision
    /// call is synchronous and the callers are on the main actor.
    static func eyes(in image: UIImage) async -> (left: CGPoint, right: CGPoint)? {
        guard let cg = image.cgImage else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        return await Task.detached(priority: .utility) {
            () -> (left: CGPoint, right: CGPoint)? in
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do { try handler.perform([request]) } catch {
                NSLog("[Hermes] face: landmark request failed - \(error.localizedDescription)")
                return nil
            }
            guard let face = (request.results ?? []).max(by: {
                $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height
            }), let marks = face.landmarks,
               let leftEye = marks.leftEye, let rightEye = marks.rightEye
            else { return nil }

            // Landmark points are normalised to the FACE BOUNDING BOX, which
            // is itself normalised to the image and bottom-left origin. Both
            // conversions happen here, once, so everything downstream is in
            // the app-wide top-left pixel convention.
            let box = face.boundingBox
            func centre(_ region: VNFaceLandmarkRegion2D) -> CGPoint? {
                let points = region.normalizedPoints
                guard !points.isEmpty else { return nil }
                let sum = points.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y))
                }
                let mean = CGPoint(x: sum.x / CGFloat(points.count),
                                   y: sum.y / CGFloat(points.count))
                let nx = box.minX + mean.x * box.width
                let ny = box.minY + mean.y * box.height
                return CGPoint(x: nx * width, y: (1 - ny) * height)
            }
            guard let l = centre(leftEye), let r = centre(rightEye) else { return nil }
            // Vision's "left eye" is the subject's left, which appears on the
            // RIGHT of the image. FaceAlignment wants them left-most first.
            return l.x <= r.x ? (l, r) : (r, l)
        }.value
    }

    /// Align, infer, normalise. Nil when no usable face is present.
    func embed(_ image: UIImage) async -> [Float]? {
        guard let eyePair = await Self.eyes(in: image),
              let cg = image.cgImage else { return nil }
        let transform = FaceAlignment.transform(leftEye: eyePair.left,
                                                rightEye: eyePair.right)
        guard transform != .identity else { return nil }

        let edge = Int(FaceAlignment.outputSize)
        guard let aligned = Self.render(cg, transform: transform, edge: edge),
              let array = Self.pixelArray(from: aligned, edge: edge) else { return nil }

        do {
            let input = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: array)]
            )
            // CoreML's async overload - it runs the inference off the
            // calling thread, which matters because Lookup calls this from
            // the main actor mid-conversation.
            let output = try await model.prediction(from: input)
            guard let name = output.featureNames.sorted().first,
                  let vector = output.featureValue(for: name)?.multiArrayValue
            else { return nil }
            var values = (0..<vector.count).map { Float(truncating: vector[$0]) }
            // L2-normalise HERE, not in the model: FaceMatcher.cosine
            // normalises defensively but the threshold is calibrated on
            // normalised vectors, and an un-normalised one would still skew
            // the max-over-photos comparison.
            let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return nil }
            for i in values.indices { values[i] /= norm }
            return values
        } catch {
            NSLog("[Hermes] face: inference failed - \(error.localizedDescription)")
            return nil
        }
    }

    /// Draw the source image through the alignment transform into a square
    /// `edge`x`edge` context.
    private static func render(
        _ image: CGImage, transform: CGAffineTransform, edge: Int
    ) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8,
            bytesPerRow: edge * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // CGContext is bottom-left origin and FaceAlignment is top-left.
        // The flip lives here, at the boundary, so the transform itself
        // stays in the app-wide convention.
        context.translateBy(x: 0, y: CGFloat(edge))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: image.width, height: image.height))
        return context.makeImage()
    }

    /// RGB, NCHW, `(pixel - 127.5) / 128` - the contract recorded in
    /// tools/export-face.md. A silently mismatched normalisation produces
    /// embeddings that look perfectly well-formed and match nothing.
    private static func pixelArray(from image: CGImage, edge: Int) -> MLMultiArray? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              let array = try? MLMultiArray(
                  shape: [1, 3, NSNumber(value: edge), NSNumber(value: edge)],
                  dataType: .float32
              ) else { return nil }
        let bytesPerRow = image.bytesPerRow
        let pointer = array.dataPointer.bindMemory(
            to: Float.self, capacity: array.count
        )
        let plane = edge * edge
        for y in 0..<edge {
            for x in 0..<edge {
                let offset = y * bytesPerRow + x * 4
                let r = Float(bytes[offset]), g = Float(bytes[offset + 1])
                let b = Float(bytes[offset + 2])
                let index = y * edge + x
                pointer[index] = (r - 127.5) / 128.0
                pointer[plane + index] = (g - 127.5) / 128.0
                pointer[2 * plane + index] = (b - 127.5) / 128.0
            }
        }
        return array
    }
}

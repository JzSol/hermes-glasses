//
// FaceEmbedder.swift
//
// The app's face -> vector service. A thin UIImage wrapper over
// FaceEmbedding, which holds the actual alignment and inference and is
// UIKit-free so tools/face-probe.swift can compile the same code on macOS.
// Keep the logic there, not here: the probe is what sets the thresholds,
// and it is only trustworthy while it measures what ships.
//
// The model is OPTIONAL at build time but REQUIRED at runtime: with no
// `faceid.mlpackage` bundled, `FaceEmbedder()` returns nil and Lookup says
// so plainly. There is deliberately no weaker fallback.
//
// That is not caution for its own sake, and it is not the ladder
// BadgeDetector/BadgeRegion follows. It was MEASURED. Apple's
// VNGenerateImageFeaturePrintRequest was the obvious no-download stand-in,
// and on this roster (`face-probe simulate`, 2026-08-16) two DIFFERENT
// people scored up to 0.87 while the SAME person dropped to ~0.53 once the
// image was reduced to glasses-stream resolution. The distributions are
// inverted: a stranger resembles you more than you do. No threshold can
// separate that, so the app would name people confidently and wrongly.
//
// A floor is worth shipping when its failure mode is silence - the badge
// band reads nothing and the wearer tries again. It is not worth shipping
// when its failure mode is a wrong name spoken about someone standing in
// front of you.
//

import Foundation
import CoreML
import UIKit

struct FaceEmbedder {
    static let modelName = "faceid"

    private let backend: FaceEmbeddingBackend
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
        guard let input = loaded.modelDescription
            .inputDescriptionsByName.keys.sorted().first else {
            NSLog("[Hermes] face: model has no inputs")
            return nil
        }
        backend = .coreML(loaded, inputName: input)
        modelID = backend.modelID
    }

    static var isAvailable: Bool { FaceEmbedder() != nil }

    /// Does this image contain a face that could be aligned? Used by the
    /// importer to report coverage before any model exists - a portrait
    /// that fails here can never be recognised, whatever the recogniser.
    static func hasDetectableFace(_ image: UIImage) async -> Bool {
        guard let cg = image.cgImage else { return false }
        return await Task.detached(priority: .utility) {
            FaceEmbedding.eyes(in: cg) != nil
        }.value
    }

    /// Align, infer, L2-normalise. Nil when no usable face is present.
    ///
    /// Detached for the same reason BadgeReader's passes are: Vision and
    /// CoreML are synchronous here and the callers are on the main actor.
    func embed(_ image: UIImage) async -> [Float]? {
        guard let cg = image.cgImage else { return nil }
        let backend = self.backend
        return await Task.detached(priority: .utility) {
            FaceEmbedding.embed(cg, backend: backend)
        }.value
    }
}

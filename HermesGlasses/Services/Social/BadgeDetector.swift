//
// BadgeDetector.swift
//
// Finds the badge inside a person crop, so OCR reads a name tag instead of
// the middle of a shirt. Wraps the bundled badge11n CoreML model
// (ultralytics export with nms=True, so Vision returns
// VNRecognizedObjectObservation directly - see tools/train-badge.md).
//
// One-shot by design: this runs on a still crop a handful of times per
// conversation, not on a video stream, so none of ObjectDetector's
// latest-wins backpressure applies. An actor because the model is loaded
// lazily once and shared.
//
// The model is OPTIONAL. When it is absent from the bundle this returns no
// detections and BadgeReader falls back to BadgeRegion's band - which is
// the behaviour that shipped before badge detection existed. That is not a
// degraded mode to apologise for; it is the floor the whole feature stands
// on.
//

import CoreGraphics
import CoreML
import Foundation
import Vision
import os

actor BadgeDetector {
    static let shared = BadgeDetector()

    /// Bundle resource name of the compiled model (see tools/train-badge.md)
    static let modelName = "badge11n"

    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "badge"
    )

    private var model: VNCoreMLModel?
    /// Set once we know there is no model to load, so a missing bundle
    /// resource is logged one time instead of on every sighting.
    private var loadFailed = false

    /// Badge boxes in the crop, unit coordinates, TOP-LEFT origin. Empty
    /// when there is no model, the request fails, or nothing was found -
    /// all three are the same answer to the caller: fall back.
    func detect(_ image: CGImage) async -> [BadgeBox] {
        guard let model = loadModelIfNeeded() else { return [] }

        let request = VNCoreMLRequest(model: model)
        // .scaleFill matches ObjectDetector and the export's letterbox-free
        // assumption; a badge crop's aspect ratio is not preserved by the
        // model input either way.
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("badge detect failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        return observations.compactMap { observation in
            guard let top = observation.labels.first else { return nil }
            return BadgeCrop.box(
                label: top.identifier,
                confidence: observation.confidence,
                visionRect: observation.boundingBox
            )
        }
    }

    // MARK: - Private

    private func loadModelIfNeeded() -> VNCoreMLModel? {
        if let model { return model }
        guard !loadFailed else { return nil }

        guard let url = Bundle.main.url(
            forResource: Self.modelName, withExtension: "mlmodelc"
        ) else {
            loadFailed = true
            logger.notice("no \(Self.modelName).mlmodelc in the bundle - badge reading falls back to the BadgeRegion band")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all // let CoreML pick the Neural Engine
            let loaded = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            model = loaded
            logger.info("badge model loaded")
            return loaded
        } catch {
            loadFailed = true
            logger.error("badge model failed to load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

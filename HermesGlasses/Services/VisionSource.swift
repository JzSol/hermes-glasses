//
// VisionSource.swift
//
// The one seam between "what Hermes sees" and which hardware it comes
// from. Five features use a camera - visual queries, "remember this
// person", conversation capture, the Lens screen, and the Photo test - and
// all five talk to this protocol, so phone mode reaches every one of them
// without a single `if phoneMode` branch at a call site.
//
// Frames arrive already reduced to what the app actually consumes: a
// UIImage to draw and a CVPixelBuffer to run YOLO on. That conversion used
// to live in LensViewModel; doing it here means the DAT SDK's VideoFrame
// type stops at this boundary.
//

import CoreMedia
import CoreVideo
import UIKit

/// One frame from whichever eye is active.
struct VisionFrame {
    /// Displayable frame. Nil if the decode failed - callers keep the last
    /// good image rather than flashing an empty view.
    let image: UIImage?
    /// Buffer for Vision/CoreML. Nil on sources that only decode to images.
    let pixelBuffer: CVPixelBuffer?
}

/// A camera Hermes can see through. Implementations own their own stream
/// lifecycle; the app only starts, stops, and asks for stills.
protocol VisionSource: AnyObject {
    /// How the photo card credits this source ("Ray-Ban camera").
    var sourceLabel: String { get }

    /// Whether a live stream is currently running.
    var isStreaming: Bool { get }

    /// Start a persistent stream. `onFrame` fires on a capture thread - hop
    /// to the main actor before touching UI state. Throws if the source is
    /// unavailable or already streaming.
    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws

    /// Tear down the live stream. Safe to call when nothing is running.
    func stopLiveStream()

    /// A single JPEG. While a live stream runs, implementations serve the
    /// freshest frame rather than opening a competing capture, so a visual
    /// query never stutters the feed.
    func capturePhoto() async throws -> Data
}

// MARK: - Glasses

extension HermesCameraManager: VisionSource {
    var sourceLabel: String { "Ray-Ban camera" }

    /// Adapts the DAT SDK's `VideoFrame` callback to `VisionFrame`. The
    /// decode happens once, here, on the SDK thread that delivered it.
    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        try await startLiveStream(
            onVideoFrame: { frame in
                onFrame(VisionFrame(
                    image: frame.makeUIImage(),
                    pixelBuffer: CMSampleBufferGetImageBuffer(frame.sampleBuffer)
                ))
            },
            onError: onError
        )
    }
}

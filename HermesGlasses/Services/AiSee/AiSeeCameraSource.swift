//
// AiSeeCameraSource.swift
//
// VisionSource adapter over AiSeeDeviceCoordinator. Hermes's five camera
// features only know VisionSource, so this is the whole AiSee camera surface
// they see. Frames arrive already decoded; a still while streaming is served
// from the latest frame by the coordinator (the same rule the Meta path uses).
//

import CoreVideo
import Foundation
import UIKit

final class AiSeeCameraSource: VisionSource, @unchecked Sendable {
    private let coordinator: AiSeeDeviceCoordinator
    private let lock = NSLock()
    private var _streaming = false
    /// Fired on `AiSeeError.deviceWedged` so the view model can take the
    /// route out of service until the glasses reconnect.
    var onWedged: (@Sendable () -> Void)?

    init(coordinator: AiSeeDeviceCoordinator) { self.coordinator = coordinator }

    var sourceLabel: String { GlassesVendor.aisee.cameraLabel }

    var isStreaming: Bool { lock.withLock { _streaming } }

    func startLiveStream(
        onFrame: @escaping @Sendable (VisionFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        guard !isStreaming else { throw HermesCameraError.streamInUse }
        try await coordinator.startLiveStream(
            onFrame: { frame in onFrame(VisionFrame(image: frame.image, pixelBuffer: frame.pixelBuffer)) },
            onError: onError,
            onTerminate: { [weak self] text in
                self?.lock.withLock { self?._streaming = false }
                if let text { onError(text) }
            })
        lock.withLock { _streaming = true }
    }

    func stopLiveStream() {
        lock.withLock { _streaming = false }
        Task { await coordinator.stopLiveStream() }
    }

    func capturePhoto() async throws -> Data {
        do {
            return try await coordinator.capturePhoto()
        } catch AiSeeError.deviceWedged {
            onWedged?()
            throw AiSeeError.deviceWedged
        }
    }
}

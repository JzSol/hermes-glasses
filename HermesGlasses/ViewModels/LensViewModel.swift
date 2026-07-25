//
// LensViewModel.swift
//
// Drives the Lens (Object Snap) view: live glasses frames in, detections
// overlaid, and a 2 s center-dwell crops the pointed-at object into a
// session-only snap strip. Snaps live in memory and die with the view -
// no persistence, no AI, no network.
//

import SwiftUI
import Observation
import CoreMedia
import MWDATCamera

/// One captured object crop. Session-only.
struct LensSnap: Identifiable {
    let id = UUID()
    let image: UIImage
    let label: String
    let date: Date
}

/// One aggregated object in the exportable log (image joined to the numbers).
struct LensLogEntry: Identifiable {
    let id: String   // the YOLO label
    let label: String
    let totalLookTime: TimeInterval
    let lookCount: Int
    let image: UIImage?
}

@MainActor
@Observable
final class LensViewModel {
    /// Stages of the snap moment: shutter flash ("Taking a pic…"), then
    /// the crop reveal ("Cropping…"). Nil outside a capture.
    enum CaptureStage: Equatable {
        case flash
        case cropping
    }

    var feedImage: UIImage?
    var detections: [Detection] = []
    var dwellProgress: Double = 0
    var targetLabel: String?
    var snaps: [LensSnap] = []
    var statusText = "Connecting to glasses…"
    var errorBanner: String?
    var isStreaming = false
    var fps = 0
    var captureStage: CaptureStage?
    /// The glasses camera grant is missing, so the stream cannot work until
    /// the user allows it in the Meta AI app.
    var needsGlassesCameraGrant = false

    /// Distinct labels logged so far - drives the Export button's enabled
    /// state (observed; the aggregator itself is ObservationIgnored).
    var loggedObjectCount = 0

    /// Seconds the reticle must cover an object before it snaps. Tunable
    /// live from the Lens screen (0.5...3.0); persisted in UserDefaults and
    /// pushed straight to the dwell tracker so the reticle fills at the new
    /// speed immediately. Lens-only - conversation capture keeps its own.
    var dwellSeconds: Double {
        didSet {
            let clamped = min(max(dwellSeconds, Self.minDwell), Self.maxDwell)
            if clamped != dwellSeconds { dwellSeconds = clamped; return }
            UserDefaults.standard.set(dwellSeconds, forKey: Self.dwellKey)
            dwell.setDwellDuration(dwellSeconds)
        }
    }

    static let minDwell = 0.5
    static let maxDwell = 3.0
    static let dwellKey = "lens_dwell_seconds"

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    /// Decided in `start()`, not at init: eligibility can change between the
    /// tap and the stream, and reading it early is what made Lens insist on
    /// glasses that weren't there.
    @ObservationIgnored private var vision: VisionSource?
    /// True when the running voice session already owns the phone camera, so
    /// this view attaches to its frames instead of starting a capture.
    @ObservationIgnored private var sharesSessionStream = false
    @ObservationIgnored private let detector = ObjectDetector()
    @ObservationIgnored private let dwell = DwellTracker()
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var fpsWindowStart = Date()
    @ObservationIgnored private var aggregator = LensLogAggregator()
    @ObservationIgnored private var logImages: [String: UIImage] = [:]
    @ObservationIgnored private var sessionStart = Date()
    @ObservationIgnored private var didStop = false

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM


        // Restore the saved dwell time (default 2 s) and sync the tracker.
        let stored = UserDefaults.standard.object(forKey: Self.dwellKey) as? Double
        dwellSeconds = min(max(stored ?? 2.0, Self.minDwell), Self.maxDwell)
        dwell.setDwellDuration(dwellSeconds)
    }

    func start() async {
        errorBanner = nil
        sessionStart = Date()

        hermesVM.logVisionDiagnostics("lens-start")
        var route = hermesVM.visionRoute

        // Connect the glasses camera WITHOUT the voice loop - opening Lens
        // must never leave the mic listening in the background. The phone
        // camera needs no DeviceSession at all.
        if route == .glasses {
            statusText = "Connecting to glasses…"
            // Check the Meta AI grant BEFORE fighting with the stream: it is
            // the documented reason a stream is refused, and the fix is one
            // tap rather than a mystery.
            if await hermesVM.glassesCameraGranted() == false {
                needsGlassesCameraGrant = true
                errorBanner = "The glasses camera isn't allowed yet."
                statusText = "Tap Allow camera to grant it in the Meta AI app"
                return
            }
            do {
                try await hermesVM.ensureCameraSession()
            } catch {
                // The glasses said no. Use the phone rather than showing a
                // dead screen - unless the user turned that off.
                guard VisionRouting.mayFallBackToPhone(
                    preference: hermesVM.phoneModePreference
                ) else {
                    errorBanner = error.localizedDescription
                    statusText = "Glasses unavailable"
                    return
                }
                NSLog("[Hermes] lens: glasses unavailable (\(error.localizedDescription)) - using iPhone")
                errorBanner = "Glasses unreachable - using the iPhone camera."
                route = .phone
            }
        }

        hermesVM.pinVisionRoute(route)
        vision = hermesVM.vision
        sharesSessionStream = hermesVM.visionStreamIsShared

        statusText = "Loading model…"
        do {
            try await detector.load()
        } catch {
            // Feed still works without boxes; keep going.
            errorBanner = "Detection model failed to load."
        }

        detector.onDetections = { [weak self] detections in
            // ObjectDetector calls this on the main queue.
            MainActor.assumeIsolated {
                self?.handle(detections: detections)
            }
        }

        await beginStream()
    }

    /// Start (or restart) the live camera stream. Assumes the camera session
    /// and detector are already set up by `start()`; used both on first open
    /// and when resuming after the History sheet paused it.
    private func beginStream() async {
        // Phone mode with a live session: the camera is already streaming for
        // the 5b feed, and iOS gives one AVCaptureSession per camera. Attach
        // to those frames rather than fighting for the device.
        if sharesSessionStream {
            hermesVM.addVisionFrameObserver(Self.observerKey) { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                }
            }
            isStreaming = true
            statusText = "Point the center at an object"
            return
        }

        guard let vision else {
            statusText = "No camera available"
            return
        }
        statusText = hermesVM.visionRoute == .phone
            ? "Starting iPhone camera…" : "Starting glasses camera…"
        do {
            try await vision.startLiveStream(
                onFrame: { [weak self] frame in
                    // Capture thread - hop to main before touching state.
                    Task { @MainActor [weak self] in
                        self?.handle(
                            image: frame.image, pixelBuffer: frame.pixelBuffer
                        )
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.errorBanner = "Camera stream error: \(message)"
                        self?.isStreaming = false
                    }
                }
            )
            isStreaming = true
            statusText = "Point the center at an object"
        } catch {
            NSLog("[Hermes] lens: \(hermesVM.visionRoute) stream failed - \(error.localizedDescription)")
            hermesVM.logVisionDiagnostics("lens-stream-failed")

            // A refused glasses stream is not the end of the road: the phone
            // has a camera. Falling back only on session failure left this
            // case sitting on a dead "Camera unavailable" screen.
            guard hermesVM.visionRoute == .glasses,
                  VisionRouting.mayFallBackToPhone(
                      preference: hermesVM.phoneModePreference
                  )
            else {
                errorBanner = error.localizedDescription
                statusText = "Camera unavailable"
                return
            }

            errorBanner = "Glasses camera unavailable - using the iPhone camera."
            hermesVM.pinVisionRoute(.phone)
            // `self.` is load-bearing: the guard above shadows `vision` with
            // the unwrapped glasses source.
            self.vision = hermesVM.vision
            sharesSessionStream = hermesVM.visionStreamIsShared
            await beginPhoneStream()
        }
    }

    /// Second attempt, on the phone. Separate from `beginStream()` so a
    /// failure here reports honestly instead of recursing.
    private func beginPhoneStream() async {
        if sharesSessionStream {
            hermesVM.addVisionFrameObserver(Self.observerKey) { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                }
            }
            isStreaming = true
            statusText = "Point the center at an object"
            return
        }
        guard let vision else {
            statusText = "No camera available"
            return
        }
        statusText = "Starting iPhone camera…"
        do {
            try await vision.startLiveStream(
                onFrame: { [weak self] frame in
                    Task { @MainActor [weak self] in
                        self?.handle(
                            image: frame.image, pixelBuffer: frame.pixelBuffer
                        )
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.errorBanner = "Camera stream error: \(message)"
                        self?.isStreaming = false
                    }
                }
            )
            isStreaming = true
            statusText = "Point the center at an object"
        } catch {
            NSLog("[Hermes] lens: iPhone fallback also failed - \(error.localizedDescription)")
            errorBanner = error.localizedDescription
            statusText = "Camera unavailable"
        }
    }

    /// Pause the live stream while the History sheet is up: stop the camera
    /// but keep the session, log, and camera-session alive. Flushes the
    /// in-progress look so its time is recorded and the dwell resets clean.
    func pauseStreaming() {
        guard isStreaming else { return }
        endStream()
        isStreaming = false
        statusText = "Paused"
        if let ended = dwell.flush(at: CACurrentMediaTime()) {
            aggregator.recordLook(
                label: ended.label, duration: ended.duration, at: Date()
            )
        }
    }

    /// Ask Meta AI for the glasses camera, then carry on where we left off.
    func grantGlassesCamera() async {
        guard await hermesVM.requestGlassesCameraAccess() else {
            errorBanner = "Still not allowed. Open the Meta AI app and enable camera access for Hermes."
            return
        }
        needsGlassesCameraGrant = false
        errorBanner = nil
        didStop = false
        await start()
    }

    private static let observerKey = "lens"

    /// Stop whichever kind of stream this view is using: detach from the
    /// session's fan-out, or tear down the capture it started itself.
    private func endStream() {
        if sharesSessionStream {
            hermesVM.removeVisionFrameObserver(Self.observerKey)
        } else {
            vision?.stopLiveStream()
        }
    }

    /// Resume after the History sheet closes.
    func resumeStreaming() {
        guard !isStreaming, !didStop else { return }
        Task { await beginStream() }
    }

    func stop() {
        guard !didStop else { return }
        didStop = true
        // Capture the object still under the reticle, then persist the log.
        if let ended = dwell.flush(at: CACurrentMediaTime()) {
            aggregator.recordLook(
                label: ended.label, duration: ended.duration, at: Date()
            )
        }
        let entries = aggregator.entries()
        if !entries.isEmpty {
            hermesVM.saveLensSession(
                startedAt: sessionStart, endedAt: Date(),
                entries: entries.map { entry in
                    LensSessionInput(
                        label: entry.label, totalLookTime: entry.totalLookTime,
                        lookCount: entry.lookCount,
                        photo: logImages[entry.label]?.jpegData(compressionQuality: 0.8)
                    )
                }
            )
        }
        endStream()
        detector.onDetections = nil
        isStreaming = false
        // Only Lens's own pin is released - a running voice session pinned
        // its route first and owns it until the session ends.
        if !hermesVM.phoneModeActive, hermesVM.connectionState == .disconnected {
            hermesVM.unpinVisionRoute()
        }
        hermesVM.releaseCameraSession()
    }

    // MARK: - Private

    private func handle(image: UIImage?, pixelBuffer: CVPixelBuffer?) {
        if let image { feedImage = image }
        if let pixelBuffer { detector.process(pixelBuffer) }

        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            fps = Int(Double(frameCount) / elapsed)
            frameCount = 0
            fpsWindowStart = Date()
        }
    }

    private func handle(detections: [Detection]) {
        self.detections = detections
        let update = dwell.update(
            detections: detections, at: CACurrentMediaTime()
        )
        dwellProgress = update.progress
        targetLabel = update.target?.label
        if let snap = update.snap, let frame = feedImage {
            aggregator.recordSnap(label: snap.label, at: Date())
            loggedObjectCount = aggregator.entries().count
            runCaptureEffect(frame: frame, detection: snap)
        }
        if let look = update.completedLook {
            aggregator.recordLook(
                label: look.label, duration: look.duration, at: Date()
            )
        }
    }

    /// The snap moment: freeze the triggering frame, flash the shutter
    /// ("Taking a pic…"), then reveal the crop ("Cropping…"). The dwell
    /// tracker's cooldown keeps the same object from re-firing meanwhile.
    private func runCaptureEffect(frame: UIImage, detection: Detection) {
        guard captureStage == nil else { return }
        Task { @MainActor in
            captureStage = .flash
            try? await Task.sleep(nanoseconds: 450_000_000)
            captureStage = .cropping
            try? await Task.sleep(nanoseconds: 550_000_000)
            if let cropped = Self.crop(frame, to: detection.rect) {
                snaps.insert(
                    LensSnap(image: cropped, label: detection.label, date: Date()),
                    at: 0
                )
                if logImages[detection.label] == nil {
                    logImages[detection.label] = cropped
                }
            }
            captureStage = nil
        }
    }

    /// The aggregated log joined to its crop images, longest-looked first.
    var logEntries: [LensLogEntry] {
        aggregator.entries().map { entry in
            LensLogEntry(
                id: entry.label, label: entry.label,
                totalLookTime: entry.totalLookTime, lookCount: entry.lookCount,
                image: logImages[entry.label]
            )
        }
    }

    /// Crop a normalized top-left-origin rect out of `image`, padded 10 %
    /// per side and clamped to the frame.
    static func crop(
        _ image: UIImage, to normalizedRect: CGRect, padding: CGFloat = 0.1
    ) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        var r = normalizedRect.insetBy(
            dx: -normalizedRect.width * padding,
            dy: -normalizedRect.height * padding
        )
        r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, !r.isEmpty else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let pixelRect = CGRect(
            x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h
        ).integral
        guard let cropped = cg.cropping(to: pixelRect) else { return nil }
        return UIImage(
            cgImage: cropped, scale: image.scale,
            orientation: image.imageOrientation
        )
    }
}

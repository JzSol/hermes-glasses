//
// LookupViewModel.swift
//
// Drives the Lookup app: live frames in, YOLO person boxes through
// PersonLookupGate (close + centered + held), then a Vision face check
// ("are they actually facing me?"), the badge OCR pipeline for a name,
// and a web lookup on that name. The result lands on the lens and in the
// session strip.
//
// Identity comes from the BADGE, never the face. The face check only
// answers "is this person oriented towards the wearer" - no recognition,
// no matching, and the photo never leaves the phone. Only the badge text
// is sent out, to the user's own configured AI provider.
//
// Camera plumbing mirrors LensViewModel: route decided at start, glasses
// falling back to the phone, shared-stream observation in phone mode, and
// the stream torn down with the view.
//

import SwiftUI
import Observation
import CoreMedia
import Vision

/// One person looked up this session. Session-only, in memory - Lookup
/// deliberately keeps no store: the web summary is a moment's context, not
/// a record about a person worth persisting.
struct LookupHit: Identifiable {
    let id = UUID()
    let image: UIImage
    let name: String
    let summary: String
    let date: Date
}

@MainActor
@Observable
final class LookupViewModel {
    enum Phase: Equatable {
        case connecting
        case scanning
        /// Fired: checking the snap actually shows a face turned this way.
        case verifying
        /// Reading the badge off the person crop.
        case reading
        case searching(name: String)
        case result
    }

    var phase: Phase = .connecting
    var feedImage: UIImage?
    /// Person boxes only, for the overlay (normalized, top-left origin).
    var personBoxes: [CGRect] = []
    /// The box the gate is holding on, nil when nobody qualifies.
    var targetBox: CGRect?
    var holdProgress: Double = 0
    var statusText = "Connecting to camera…"
    var errorBanner: String?
    var isStreaming = false
    var needsGlassesCameraGrant = false
    /// Newest first. The latest hit is the result card.
    var hits: [LookupHit] = []

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    @ObservationIgnored private var vision: VisionSource?
    @ObservationIgnored private var sharesSessionStream = false
    @ObservationIgnored private let detector = ObjectDetector()
    @ObservationIgnored private var gate = PersonLookupGate()
    @ObservationIgnored private let client = DirectClient()
    @ObservationIgnored private var didStop = false

    private static let observerKey = "lookup"

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
    }

    // MARK: - Lifecycle (mirrors LensViewModel)

    func start() async {
        errorBanner = nil
        hermesVM.logVisionDiagnostics("lookup-start")
        var route = hermesVM.visionRoute

        if route == .glasses {
            statusText = "Connecting to glasses…"
            if await hermesVM.glassesCameraGranted() == false {
                needsGlassesCameraGrant = true
                errorBanner = "The glasses camera isn't allowed yet."
                statusText = "Tap Allow camera to grant it in the Meta AI app"
                return
            }
            do {
                try await hermesVM.ensureCameraSession()
            } catch {
                guard VisionRouting.mayFallBackToPhone(
                    preference: hermesVM.phoneModePreference
                ) else {
                    errorBanner = error.localizedDescription
                    statusText = "Glasses unavailable"
                    return
                }
                NSLog("[Hermes] lookup: glasses unavailable (\(error.localizedDescription)) - using iPhone")
                errorBanner = "Glasses unreachable - using the iPhone camera."
                route = .phone
            }
        }

        hermesVM.pinVisionRoute(route)
        vision = hermesVM.vision
        sharesSessionStream = hermesVM.visionStreamIsShared
        // Result cards go to the real lens even without a voice session.
        hermesVM.attachDisplayToCameraSession()

        statusText = "Loading model…"
        do {
            try await detector.load()
        } catch {
            // Without boxes the gate can never fire - unlike Lens, this is
            // fatal to the feature, so say so instead of streaming quietly.
            errorBanner = "Detection model failed to load."
        }

        detector.onDetections = { [weak self] detections in
            MainActor.assumeIsolated {
                self?.handle(detections: detections)
            }
        }

        await beginStream()
    }

    private func beginStream() async {
        if sharesSessionStream {
            hermesVM.addVisionFrameObserver(Self.observerKey) { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                }
            }
            streamStarted()
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
                    Task { @MainActor [weak self] in
                        self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.errorBanner = "Camera stream error: \(message)"
                        self?.isStreaming = false
                    }
                }
            )
            streamStarted()
        } catch {
            NSLog("[Hermes] lookup: \(hermesVM.visionRoute) stream failed - \(error.localizedDescription)")
            hermesVM.logVisionDiagnostics("lookup-stream-failed")

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
            // `self.` is load-bearing: the guard above shadows `vision`.
            self.vision = hermesVM.vision
            sharesSessionStream = hermesVM.visionStreamIsShared
            await beginPhoneStream()
        }
    }

    /// Second attempt, on the phone - separate so a failure here reports
    /// honestly instead of recursing.
    private func beginPhoneStream() async {
        if sharesSessionStream {
            hermesVM.addVisionFrameObserver(Self.observerKey) { [weak self] frame in
                MainActor.assumeIsolated {
                    self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                }
            }
            streamStarted()
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
                        self?.handle(image: frame.image, pixelBuffer: frame.pixelBuffer)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.errorBanner = "Camera stream error: \(message)"
                        self?.isStreaming = false
                    }
                }
            )
            streamStarted()
        } catch {
            NSLog("[Hermes] lookup: iPhone fallback also failed - \(error.localizedDescription)")
            errorBanner = error.localizedDescription
            statusText = "Camera unavailable"
        }
    }

    private func streamStarted() {
        isStreaming = true
        phase = .scanning
        statusText = "Face someone close by - hold steady to look them up"
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

    func stop() {
        guard !didStop else { return }
        didStop = true
        if sharesSessionStream {
            hermesVM.removeVisionFrameObserver(Self.observerKey)
        } else {
            vision?.stopLiveStream()
        }
        detector.onDetections = nil
        isStreaming = false
        // Only Lookup's own pin is released - a running voice session
        // pinned its route first and owns it until the session ends.
        if !hermesVM.phoneModeActive, hermesVM.connectionState == .disconnected {
            hermesVM.unpinVisionRoute()
        }
        // Before releaseCameraSession - the display capability dies with it.
        hermesVM.detachDisplayFromCameraSession()
        hermesVM.releaseCameraSession()
    }

    // MARK: - Frames and detections

    private func handle(image: UIImage?, pixelBuffer: CVPixelBuffer?) {
        if let image { feedImage = image }
        if let pixelBuffer { detector.process(pixelBuffer) }
    }

    private func handle(detections: [Detection]) {
        let persons = detections.filter { $0.label == "person" }.map(\.rect)
        personBoxes = persons

        // The gate only advances while scanning - a lookup in flight keeps
        // the frozen state on screen.
        guard phase == .scanning else { return }

        let update = gate.update(personBoxes: persons, at: CACurrentMediaTime())
        targetBox = update.target
        holdProgress = update.progress

        if let rect = update.fire {
            phase = .verifying
            statusText = "Checking they're facing you…"
            Task { await processCandidate(rect: rect) }
        }
    }

    // MARK: - The snap pipeline

    private func processCandidate(rect: CGRect) async {
        guard let frame = feedImage,
              let crop = LensViewModel.crop(frame, to: rect) else {
            gate.rejected(at: CACurrentMediaTime())
            backToScanning("Lost them - hold steady")
            return
        }

        // Facing check: face DETECTION only, on-device, and only to answer
        // "are they turned towards the wearer". Someone showing their back
        // or profile is not being faced, so no lookup.
        guard await Self.hasFrontalFace(in: crop) else {
            gate.rejected(at: CACurrentMediaTime())
            backToScanning("Waiting for them to face you…")
            return
        }

        phase = .reading
        statusText = "Reading their badge…"
        let badge = await BadgeReader.readBadge(from: crop)
        guard let name = badge?.name else {
            gate.rejected(at: CACurrentMediaTime())
            backToScanning("Couldn't read a badge name - get their badge in view")
            return
        }

        // From here the snap is spent, whatever the web says.
        gate.fired(at: CACurrentMediaTime())

        guard DirectClient.hasKey(for: DirectClient.providerID)
                || !DirectClient.provider.requiresKey else {
            finish(crop: crop, name: name,
                   summary: "Add an AI provider key in Settings to search the web for people.")
            return
        }

        phase = .searching(name: name)
        statusText = "Searching the web for \(name)…"
        hermesVM.showLookupSearchingOnLens(name: name)

        do {
            let summary = try await PersonWebLookup.lookup(
                name: name, org: badge?.org, title: badge?.title, client: client
            )
            finish(crop: crop, name: name,
                   summary: summary.isEmpty ? "Couldn't find anything solid online." : summary)
        } catch {
            NSLog("[Hermes] lookup: web search failed - \(error.localizedDescription)")
            finish(crop: crop, name: name,
                   summary: "Web lookup failed: \(error.localizedDescription)")
        }
    }

    private func finish(crop: UIImage, name: String, summary: String) {
        hits.insert(
            LookupHit(image: crop, name: name, summary: summary, date: Date()),
            at: 0
        )
        phase = .result
        statusText = "Face someone close by - hold steady to look them up"
        hermesVM.showPersonLookupOnLens(name: name, info: summary)
        // Scanning resumes underneath the result card; the gate's fired
        // cooldown keeps the same person from immediately re-firing.
        phase = .scanning
    }

    private func backToScanning(_ message: String) {
        statusText = message
        phase = .scanning
    }

    /// Does this person crop contain a face turned roughly towards the
    /// camera? Detection only - VNDetectFaceRectanglesRequest finds faces
    /// and estimates yaw; nothing here identifies anyone. Detached for the
    /// same reason BadgeReader's passes are: the Vision call is synchronous
    /// and the caller is on the main actor.
    static func hasFrontalFace(in image: UIImage) async -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return await Task.detached(priority: .utility) { () -> Bool in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[Hermes] lookup: face request failed - \(error.localizedDescription)")
                return false
            }
            return (request.results ?? []).contains { face in
                // A face at conversational range is a decent slice of the
                // crop; tiny ones are bystanders in the background.
                guard face.boundingBox.width >= 0.12 else { return false }
                // Yaw ±~35° counts as facing. When Vision doesn't report
                // yaw, finding the face at all is the (near-frontal) signal.
                guard let yaw = face.yaw?.doubleValue else { return true }
                return abs(yaw) <= 0.62
            }
        }.value
    }
}

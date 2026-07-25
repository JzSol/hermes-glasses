//
// PermissionsCoordinator.swift
//
// The three permissions Hermes cannot work without, behind one surface, so
// the onboarding wizard, Settings, and startSession() all agree on what has
// been granted.
//
// Mic and speech are essential - no voice loop without them. Camera is
// needed only for phone mode (design 5b); the glasses camera is granted
// separately through the Meta AI app, which is why it isn't here.
//
// Location and motion stay just-in-time: they are optional context
// features, already requested lazily by DeviceContextProvider and
// NavigationController, and asking for location before the user has a
// reason to say yes is how you get a no.
//

import AVFoundation
import Observation
import Speech
import UIKit

enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .camera: return "Camera"
        }
    }

    var reason: String {
        switch self {
        case .microphone:
            return "To hear your questions."
        case .speechRecognition:
            return "To turn them into text on this device - audio never leaves your phone."
        case .camera:
            return "So this iPhone can be the eye when you have no glasses on."
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .speechRecognition: return "text.bubble"
        case .camera: return "camera"
        }
    }

    /// Whether the voice loop is dead without it.
    var isEssential: Bool {
        switch self {
        case .microphone, .speechRecognition: return true
        case .camera: return false
        }
    }
}

enum PermissionState: Equatable {
    case notDetermined
    case granted
    case denied

    var label: String {
        switch self {
        case .notDetermined: return "Needed"
        case .granted: return "Allowed"
        case .denied: return "Denied"
        }
    }

    /// Resolved either way - the wizard may move on.
    var isDecided: Bool { self != .notDetermined }
}

@MainActor
@Observable
final class PermissionsCoordinator {
    /// Bumped after every request so views re-read the (synchronously
    /// queried) system state.
    private var revision = 0

    func state(of kind: PermissionKind) -> PermissionState {
        _ = revision
        switch kind {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
    }

    /// Requests one permission. Returns the resulting state; already-decided
    /// permissions return immediately without a dialog.
    @discardableResult
    func request(_ kind: PermissionKind) async -> PermissionState {
        guard state(of: kind) == .notDetermined else { return state(of: kind) }

        switch kind {
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        revision &+= 1
        return state(of: kind)
    }

    /// Requests all three in order. Sequential on purpose: iOS stacks
    /// concurrent permission dialogs and the user sees only the last one.
    func requestAll() async {
        for kind in PermissionKind.allCases {
            await request(kind)
        }
    }

    /// Mic and speech both granted - the voice loop can run.
    var essentialsGranted: Bool {
        PermissionKind.allCases
            .filter(\.isEssential)
            .allSatisfy { state(of: $0) == .granted }
    }

    /// Every essential permission has an answer, so the wizard can move on
    /// even if the answer was no.
    var essentialsDecided: Bool {
        PermissionKind.allCases
            .filter(\.isEssential)
            .allSatisfy { state(of: $0).isDecided }
    }

    /// Any permission was refused, so somewhere a feature is off and the UI
    /// should say which.
    var hasDenial: Bool {
        PermissionKind.allCases.contains { state(of: $0) == .denied }
    }

    /// A denial can only be undone in Settings.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

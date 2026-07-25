//
// VisionRouting.swift
//
// Which eye a session uses, as pure logic. Foundation only, so it
// unit-tests standalone with swiftc like DwellTracker.
//
// This exists because the first cut got the question wrong. It asked "are
// glasses PAIRED" (`registrationState == .registered && !devices.isEmpty`)
// when the question is "can a glasses session be CREATED". Glasses that are
// paired but out of range answer yes to the first and no to the second, so
// Auto never fell back and Lens, Start listening, and the encounter photo
// all took the glasses path and failed with `noEligibleDevice`.
//
// The caller now passes eligibility straight from the SDK's own selector
// (`AutoDeviceSelector.activeDevice != nil`) - the very thing
// `createSession` resolves - and the rules below are the only interpretation
// layered on top.
//

import Foundation

/// Which eye a session sees through.
enum VisionRoute: String, Equatable {
    case glasses
    case phone
}

/// How willing the app is to fall back to the iPhone camera (design 5a's
/// "Use this iPhone" row).
enum PhoneModePreference: String, CaseIterable, Identifiable {
    /// Glasses when they can actually be reached, phone when they can't.
    /// The default, and what makes `Start listening` work with no glasses.
    case auto
    /// Phone even with glasses connected - for demoing the lens on a screen.
    case always
    /// Never fall back. No glasses means no session, and it says so.
    case off

    static let storageKey = "phone_mode_preference"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .always: return "Always"
        case .off: return "Off"
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return "Uses your glasses when they're reachable and this iPhone when they aren't."
        case .always:
            return "Always uses this iPhone, even with glasses connected."
        case .off:
            return "Never falls back to the iPhone. Without glasses there's no session."
        }
    }
}

enum VisionRouting {
    /// - Parameter glassesEligible: whether the SDK can currently resolve a
    ///   device for a session. NOT whether glasses are paired.
    static func route(
        glassesEligible: Bool, preference: PhoneModePreference
    ) -> VisionRoute {
        switch preference {
        case .always:
            return .phone
        case .off:
            return .glasses
        case .auto:
            return glassesEligible ? .glasses : .phone
        }
    }

    /// False only when the user turned the fallback off and has no reachable
    /// glasses - the one case where a dead Start button is the honest answer.
    static func canStartSession(
        glassesEligible: Bool, preference: PhoneModePreference
    ) -> Bool {
        route(glassesEligible: glassesEligible, preference: preference) == .phone
            || glassesEligible
    }

    /// Whether a failed glasses attempt may retry on the phone. Belt to the
    /// predicate's braces: eligibility can lapse between the check and the
    /// session start, and the user should not have to care.
    static func mayFallBackToPhone(preference: PhoneModePreference) -> Bool {
        preference != .off
    }
}

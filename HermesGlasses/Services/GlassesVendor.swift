//
// GlassesVendor.swift
//
// Which glasses "glasses" means. Meta Ray-Ban goes through the DAT SDK; AiSee
// through AiSeeGlassKit. VisionRoute stays {glasses, phone} - this enum only
// decides what the glasses route resolves to. Foundation only, swiftc-tested.
//

import Foundation

enum GlassesVendor: String, CaseIterable, Identifiable {
    case meta
    case aisee

    static let storageKey = "glasses_vendor"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meta: return "Meta Ray-Ban"
        case .aisee: return "AiSee"
        }
    }

    /// How the photo card credits the source.
    var cameraLabel: String {
        switch self {
        case .meta: return "Ray-Ban camera"
        case .aisee: return "AiSee camera"
        }
    }

    /// Only Ray-Ban Display has a lens HUD; AiSee has none, so every display
    /// setting and call is skipped for it.
    var supportsDisplay: Bool { self == .meta }

    var usesMetaSDK: Bool { self == .meta }

    static func load(from defaults: UserDefaults = .standard) -> GlassesVendor {
        GlassesVendor(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .meta
    }

    /// "Can a glasses session be created right now" for the selected vendor.
    /// Meta: the SDK's own selector has an active device. AiSee: the kit is
    /// connected and the camera has not wedged (FINDINGS §1 - only a power
    /// cycle clears that, so the route stays ineligible until reconnect).
    static func glassesEligible(
        vendor: GlassesVendor, metaDeviceActive: Bool, aiseeConnected: Bool, aiseeWedged: Bool
    ) -> Bool {
        switch vendor {
        case .meta: return metaDeviceActive
        case .aisee: return aiseeConnected && !aiseeWedged
        }
    }
}

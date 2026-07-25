//
// HermesApp.swift
//
// What a Hermes "app" is, as data.
//
// Lens, People, Map and Log were each written by hand, and they turned out
// to be the same thing four times over: a voice trigger, a set of hardware
// capabilities, a lens surface, a phone surface, a store under Application
// Support, and usually an export. This describes that shape so the drawer,
// the "What can I say?" page, and any future app all read from one list
// instead of three hand-maintained ones.
//
// Deliberately NOT a plugin runtime. It carries no views and no closures -
// wiring a screen needs the view models, and that belongs in the view
// layer. Keeping this a value type is what makes it Foundation-only and
// testable, and it is the piece a fifth app will push on first.
//

import Foundation

/// What an app needs from the hardware. Drives the capability chips in the
/// drawer, and is the honest place to state a dependency that would
/// otherwise only show up as a failure at runtime.
enum HermesAppCapability: String, CaseIterable, Identifiable {
    case vision       // a camera - glasses or, in phone mode, the iPhone
    case microphone   // speech in
    case location     // where you are, and which way you face
    case lens         // draws on the glasses display
    case storage      // keeps records between sessions
    case export       // can hand you a file

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vision: return "Camera"
        case .microphone: return "Voice"
        case .location: return "Location"
        case .lens: return "Lens"
        case .storage: return "Saves data"
        case .export: return "Export"
        }
    }

    var systemImage: String {
        switch self {
        case .vision: return "camera"
        case .microphone: return "mic"
        case .location: return "location"
        case .lens: return "eyeglasses"
        case .storage: return "internaldrive"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// How the app takes over the screen.
enum HermesAppPresentation: String, Equatable {
    /// A sheet you can swipe away.
    case sheet
    /// Full screen with an explicit exit - for anything holding a live
    /// camera stream, where a stray drag-dismiss would tear it down.
    case fullScreen
}

struct HermesApp: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    /// One line, shown in the drawer.
    let summary: String
    let capabilities: [HermesAppCapability]
    let presentation: HermesAppPresentation
    /// `VoiceCommandGroup` ids this app owns, so the drawer and the
    /// "What can I say?" page cannot disagree about what launches it.
    let voiceGroupIDs: [String]
    /// False when the iPhone can stand in for the glasses (phone mode).
    /// Only Lens-style live capture is affected; review screens never are.
    let requiresGlasses: Bool

    var isVoiceLaunchable: Bool { !voiceGroupIDs.isEmpty }
}

enum HermesAppRegistry {
    /// Every app the app knows about. Order is the order they appear.
    static let all: [HermesApp] = [lens, people, map, log]

    /// Shown as the quick-action row under the conversation. The rest live
    /// in the drawer - the row is for reach, not for completeness.
    static let pinnedCount = 4

    static var pinned: [HermesApp] { Array(all.prefix(pinnedCount)) }

    /// True once there is more to show than the row holds.
    static var hasOverflow: Bool { all.count > pinnedCount }

    static func app(id: String) -> HermesApp? {
        all.first { $0.id == id }
    }

    // MARK: - The four

    static let lens = HermesApp(
        id: "lens",
        title: "Lens",
        systemImage: "camera.viewfinder",
        summary: "Hold the reticle on a thing to log what you looked at.",
        capabilities: [.vision, .lens, .storage, .export],
        presentation: .fullScreen,
        voiceGroupIDs: [],
        requiresGlasses: false
    )

    static let people = HermesApp(
        id: "people",
        title: "People",
        systemImage: "person.crop.circle",
        summary: "Remember who you met, with a photo and a spoken note.",
        capabilities: [.vision, .microphone, .storage],
        presentation: .sheet,
        voiceGroupIDs: ["people", "people-cancel", "conversation"],
        requiresGlasses: false
    )

    static let map = HermesApp(
        id: "map",
        title: "Map",
        systemImage: "mappin.and.ellipse",
        summary: "Walk or drive somewhere, with the route on your lens.",
        capabilities: [.location, .lens],
        presentation: .sheet,
        voiceGroupIDs: ["navigate", "navigate-stop"],
        requiresGlasses: false
    )

    static let log = HermesApp(
        id: "log",
        title: "Log",
        systemImage: "list.bullet.rectangle",
        summary: "Every Lens session, with look-times and a PDF export.",
        capabilities: [.storage, .export],
        presentation: .sheet,
        voiceGroupIDs: [],
        requiresGlasses: false
    )
}

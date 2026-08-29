//
// GlassesKeyMap.swift
//
// Physical buttons on AiSee glasses → Hermes actions. The SDK only reports
// presses (key index), so single vs double tap is derived here: a second
// press of the same key inside `doubleTapWindow` upgrades the pending single
// to a double. A single is therefore reported after the window elapses, not
// on the press itself - the price of having a double tap at all.
//
// Foundation only, swiftc-tested (tests/glasses-keys).
//

import Foundation

/// What a button gesture does. Raw values are the stored strings.
enum GlassesKeyAction: String, CaseIterable, Identifiable {
    case none
    case toggleListening
    case visualQuery
    case snapPhoto
    case rememberPerson

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nothing"
        case .toggleListening: return "Start / stop listening"
        case .visualQuery: return "What am I looking at?"
        case .snapPhoto: return "Snap a photo to the chat"
        case .rememberPerson: return "Remember this person"
        }
    }
}

enum GlassesKeyGesture: String, CaseIterable, Identifiable {
    case single
    case double

    var id: String { rawValue }
    var label: String { self == .single ? "Tap" : "Double tap" }
}

/// One slot in the map: key N, gesture G.
struct GlassesKeySlot: Hashable {
    let key: Int
    let gesture: GlassesKeyGesture

    /// Storage key, e.g. "1.single".
    var storageKey: String { "\(key).\(gesture.rawValue)" }
}

/// The user's mapping, persisted as a `[String: String]` under
/// `GlassesKeyMap.storageKey`. Keys 1–3 exist on the AiSee glasses.
struct GlassesKeyMap: Equatable {
    static let storageKey = "aisee_key_map"
    static let keys = [1, 2, 3]

    static let defaults = GlassesKeyMap(entries: [
        GlassesKeySlot(key: 1, gesture: .single): .toggleListening,
        GlassesKeySlot(key: 1, gesture: .double): .visualQuery,
    ])

    var entries: [GlassesKeySlot: GlassesKeyAction]

    func action(for slot: GlassesKeySlot) -> GlassesKeyAction {
        entries[slot] ?? .none
    }

    mutating func set(_ action: GlassesKeyAction, for slot: GlassesKeySlot) {
        if action == .none { entries.removeValue(forKey: slot) } else { entries[slot] = action }
    }

    // MARK: Persistence

    static func load(from defaults: UserDefaults = .standard) -> GlassesKeyMap {
        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else {
            return .defaults
        }
        var map = GlassesKeyMap(entries: [:])
        for (slotKey, actionRaw) in raw {
            let parts = slotKey.split(separator: ".")
            guard parts.count == 2, let key = Int(parts[0]),
                  let gesture = GlassesKeyGesture(rawValue: String(parts[1])),
                  let action = GlassesKeyAction(rawValue: actionRaw) else { continue }
            map.set(action, for: GlassesKeySlot(key: key, gesture: gesture))
        }
        return map
    }

    func save(to defaults: UserDefaults = .standard) {
        var raw: [String: String] = [:]
        for (slot, action) in entries { raw[slot.storageKey] = action.rawValue }
        defaults.set(raw, forKey: Self.storageKey)
    }
}

/// Turns raw presses into single/double gestures. Pure: the host supplies
/// timestamps and schedules the flush, so this is testable without timers.
struct GlassesKeyGestureDetector {
    static let doubleTapWindow: TimeInterval = 0.4

    private var pending: (key: Int, at: Date)?

    /// Feed one press. Returns a completed `.double` immediately when this
    /// press pairs with a pending one on the same key; otherwise records the
    /// press as pending and returns nil - call `flush(now:)` once the window
    /// has elapsed to get the `.single`.
    mutating func press(key: Int, at now: Date) -> (key: Int, gesture: GlassesKeyGesture)? {
        if let p = pending, p.key == key, now.timeIntervalSince(p.at) <= Self.doubleTapWindow {
            pending = nil
            return (key, .double)
        }
        // A press on a different key ends the pending one as a single; the
        // caller gets that single on the next flush, so report it here so it
        // is not lost.
        pending = (key, now)
        return nil
    }

    /// Resolve the pending press as a single tap once the window has passed.
    mutating func flush(now: Date) -> (key: Int, gesture: GlassesKeyGesture)? {
        guard let p = pending, now.timeIntervalSince(p.at) > Self.doubleTapWindow else { return nil }
        pending = nil
        return (p.key, .single)
    }

    /// When the host should call `flush` (the pending press's deadline).
    var nextFlushAt: Date? { pending.map { $0.at.addingTimeInterval(Self.doubleTapWindow + 0.01) } }
}

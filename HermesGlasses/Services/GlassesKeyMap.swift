//
// GlassesKeyMap.swift
//
// Physical button on AiSee glasses → Hermes actions. The glasses have ONE
// button and do the gesture detection in firmware: the SDK reports key 1 for
// a tap, key 2 for a double tap, key 3 for a triple tap. Hermes just maps
// each key index to an action.
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

/// The user's mapping, persisted as `[String: String]` ("1" → action raw
/// value) under `GlassesKeyMap.storageKey`.
struct GlassesKeyMap: Equatable {
    static let storageKey = "aisee_key_map"
    /// Key index as the SDK reports it → what the wearer did.
    static let keys = [1, 2, 3]

    static func label(forKey key: Int) -> String {
        switch key {
        case 1: return "Tap"
        case 2: return "Double tap"
        case 3: return "Triple tap"
        default: return "Key \(key)"
        }
    }

    static let defaults = GlassesKeyMap(entries: [1: .toggleListening, 2: .visualQuery])

    var entries: [Int: GlassesKeyAction]

    func action(forKey key: Int) -> GlassesKeyAction { entries[key] ?? .none }

    mutating func set(_ action: GlassesKeyAction, forKey key: Int) {
        if action == .none { entries.removeValue(forKey: key) } else { entries[key] = action }
    }

    // MARK: Persistence

    static func load(from defaults: UserDefaults = .standard) -> GlassesKeyMap {
        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else {
            return .defaults
        }
        var map = GlassesKeyMap(entries: [:])
        for (keyText, actionRaw) in raw {
            // Accepts "1" and the earlier "1.single" form; "N.double" entries
            // from that scheme are dropped - the glasses report doubles as key 2.
            let head = keyText.split(separator: ".").first.map(String.init) ?? keyText
            guard let key = Int(head), keys.contains(key),
                  !keyText.hasSuffix(".double"),
                  let action = GlassesKeyAction(rawValue: actionRaw) else { continue }
            map.set(action, forKey: key)
        }
        return map
    }

    func save(to defaults: UserDefaults = .standard) {
        var raw: [String: String] = [:]
        for (key, action) in entries { raw[String(key)] = action.rawValue }
        defaults.set(raw, forKey: Self.storageKey)
    }
}

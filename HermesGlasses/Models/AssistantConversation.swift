//
// AssistantConversation.swift
//
// Presentation-only conversation types shared by the full Hermes app and
// the camera-free Adam target. Foundation-only by design: neither target's
// session, audio, camera, or wearable SDK owner crosses this boundary.
//

import Foundation

struct AssistantConversationTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let userText: String
    let agentText: String
    let timestamp: Date
    var photo: Data?
    /// The user-facing camera/source name for `photo`, when one exists.
    var photoSource: String?

    init(
        id: UUID = UUID(),
        userText: String,
        agentText: String,
        timestamp: Date,
        photo: Data? = nil,
        photoSource: String? = nil
    ) {
        self.id = id
        self.userText = userText
        self.agentText = agentText
        self.timestamp = timestamp
        self.photo = photo
        self.photoSource = photoSource
    }
}

/// Existing Hermes call sites keep their domain name while both app targets
/// compile the same presentation model.
typealias ConversationTurn = AssistantConversationTurn

struct AssistantReplyChoice: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

enum AssistantConversationActivity: Equatable, Sendable {
    case idle
    case processing(String)
    case speaking(String)
}

/// Bounded transcript storage for lightweight session owners such as Adam.
/// The full Hermes session already owns equivalent retention and can keep its
/// existing array while sharing the same turn value type.
struct AssistantConversationHistory: Equatable, Sendable {
    let limit: Int
    private(set) var turns: [ConversationTurn] = []

    init(limit: Int = 50) {
        self.limit = max(1, limit)
    }

    mutating func append(_ turn: ConversationTurn) {
        turns.append(turn)
        if turns.count > limit {
            turns.removeFirst(turns.count - limit)
        }
    }

    mutating func clear() {
        turns.removeAll(keepingCapacity: true)
    }
}

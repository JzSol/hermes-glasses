//
// RosterPerson.swift
//
// One person in the imported lookup roster: who they are, the portraits
// that stand for them, and the face embeddings computed from those
// portraits at import time.
//
// Embeddings are STORED, not recomputed at launch. 45 people is seconds of
// CoreML work that has no business happening on the path to a lens frame.
//
// They are also stamped with the model that produced them. Vectors from one
// model are meaningless to another, and comparing across a model swap would
// produce confident nonsense rather than an obvious failure - so the swap is
// detected and the roster is marked stale instead.
//

import Foundation

struct RosterPerson: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var org: String?
    var title: String?
    var notes: String?
    /// Filenames inside the store's photos/ directory, in import order.
    var photoFilenames: [String]
    /// One L2-normalised vector per photo that yielded a usable face.
    /// SHORTER than `photoFilenames` when a portrait had no findable face -
    /// never assume the two arrays line up index for index.
    var embeddings: [[Float]]
    /// The `FaceEmbedder` model identity these embeddings came from.
    var modelID: String?

    init(
        id: UUID = UUID(), name: String, org: String? = nil,
        title: String? = nil, notes: String? = nil,
        photoFilenames: [String] = [], embeddings: [[Float]] = [],
        modelID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.org = org
        self.title = title
        self.notes = notes
        self.photoFilenames = photoFilenames
        self.embeddings = embeddings
        self.modelID = modelID
    }

    /// Everything under the name, for the lens card and the result row.
    /// Empty when the roster carried nothing but a name - which is the case
    /// for every entry in today's folder, so callers must handle it.
    var detailLine: String {
        [title, org, notes]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// A person with no embedding can never be matched by face - they were
    /// imported for their details alone, or every portrait failed. The
    /// roster screen shows this, because otherwise it is invisible until
    /// the moment they are standing in front of you.
    var isMatchable: Bool { !embeddings.isEmpty }
}

/// One entry in an optional `people.json` sitting beside the photos. The
/// roster that exists today has no such file; this is how org/title/notes
/// arrive when someone wants them.
struct RosterDetails: Codable, Equatable {
    let name: String
    let org: String?
    let title: String?
    let notes: String?
    /// Explicit photo list, relative to the roster folder. When present it
    /// replaces whatever the folder walk attributed to this person.
    let photos: [String]?
}

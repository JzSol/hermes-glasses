//
// FaceMatcher.swift
//
// Given a probe embedding and the roster, decide who this is - or refuse.
//
// The accept rule is a threshold AND a runner-up margin, and the margin is
// the half that matters. Cosine similarity always has a nearest neighbour,
// so a threshold alone elects one for every face it ever sees, including
// faces belonging to nobody in the roster. Two roster members who look
// alike is exactly the case where a confident wrong name does real damage -
// the person is standing in front of the wearer - and `ambiguous` is the
// honest answer there.
//
// The threshold is checked BEFORE the margin: two equally distant strangers
// are not in the roster at all, and reporting "too close to call" would
// imply they were.
//
// A person's score is the MAX over their photos, not the mean: one poor
// portrait must not drag down a good one, which is what a roster holding a
// frontal and a profile shot of the same person would otherwise do. The
// runner-up is always a DIFFERENT person, or anyone with two good portraits
// would be ambiguous with themselves and could never be identified.
//
// Pure arithmetic - no Vision, no CoreML, no UIKit - so the whole decision
// is tested standalone in tests/face-match/.
//

import Foundation

struct FaceMatcher {
    /// Top-1 similarity must reach this. Measured with tools/face-probe.swift
    /// `separation`, then re-checked against device crops with `live`.
    /// Never guessed - see tools/export-face.md.
    var acceptThreshold: Float
    /// And must beat the best OTHER person by this much.
    var margin: Float

    enum Reason: Equatable {
        case emptyRoster
        case belowThreshold(best: Float)
        case ambiguous(best: Float, runnerUp: Float)
    }

    enum Result: Equatable {
        case match(personID: UUID, score: Float)
        case unknown(Reason)
    }

    /// Cosine similarity. `FaceEmbedder` L2-normalises its vectors, so this
    /// is a dot product - but it normalises defensively anyway, because a
    /// silently un-normalised vector would otherwise inflate every score
    /// past 1 and make the threshold meaningless.
    ///
    /// Mismatched, empty or zero-length vectors score 0 rather than
    /// trapping or returning NaN: a malformed embedding must match nobody,
    /// not crash the Lookup app mid-conversation.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    func match(probe: [Float], gallery: [RosterPerson]) -> Result {
        let matchable = gallery.filter(\.isMatchable)
        guard !matchable.isEmpty else { return .unknown(.emptyRoster) }
        guard !probe.isEmpty else { return .unknown(.belowThreshold(best: 0)) }

        // One score per person: their best-matching photo.
        var scored: [(person: RosterPerson, score: Float)] = []
        for person in matchable {
            let best = person.embeddings
                .map { Self.cosine(probe, $0) }
                .max() ?? -1
            scored.append((person, best))
        }
        scored.sort { $0.score > $1.score }

        guard let top = scored.first else { return .unknown(.emptyRoster) }
        guard top.score >= acceptThreshold else {
            return .unknown(.belowThreshold(best: top.score))
        }
        // The runner-up is the next DIFFERENT person; with a roster of one
        // there is nobody to be confused with, so the threshold stands alone.
        if let runnerUp = scored.dropFirst().first {
            guard top.score - runnerUp.score >= margin else {
                return .unknown(.ambiguous(best: top.score, runnerUp: runnerUp.score))
            }
        }
        return .match(personID: top.person.id, score: top.score)
    }
}

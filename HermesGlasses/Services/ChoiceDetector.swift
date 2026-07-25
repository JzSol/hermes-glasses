//
// ChoiceDetector.swift
//
// Pulls selectable options out of a reply, so a multiple-choice answer can
// be answered by tapping rather than by reading the letters back aloud.
// "A) Sydney, B) Melbourne, C) Canberra, or D) Perth" becomes four buttons
// on the lens, in place of the generic Stop / Repeat / New chat.
//
// Deliberately conservative. A false positive is worse than a miss: it
// replaces the controls a wearer needs with nonsense, on a display they
// cannot easily escape. So a list must be unambiguous - at least two
// markers, in ascending order, each with text after it - or this returns
// nothing and the normal buttons stay.
//
// Foundation only, so it unit-tests standalone with swiftc.
//

import Foundation

struct ReplyChoice: Equatable, Identifiable {
    /// "A", "3", or "•" - what the reply called this option.
    let key: String
    /// The option's words, trimmed of punctuation.
    let label: String

    var id: String { key + label }

    /// What to send back when the user picks this. The words, not the
    /// letter: "C" alone reads as noise to the assistant, "Canberra" is an
    /// answer that stands on its own in the transcript.
    var reply: String { label.isEmpty ? key : label }

    /// Trimmed to fit a lens button without wrapping.
    var shortLabel: String {
        guard label.count > 22 else { return label }
        return String(label.prefix(21)) + "…"
    }
}

enum ChoiceDetector {
    /// The lens can show a few buttons before they stop being tappable.
    static let maxChoices = 5

    static func choices(in reply: String) -> [ReplyChoice] {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3 else { return [] }

        // Bullets first: a line-led list is unambiguous, and its items can
        // legitimately contain "or" and commas that would confuse the
        // marker scan.
        let bullets = bulletChoices(in: trimmed)
        if bullets.count >= 2 { return Array(bullets.prefix(maxChoices)) }

        let markers = markerChoices(in: trimmed)
        if markers.count >= 2 { return Array(markers.prefix(maxChoices)) }

        return []
    }

    // MARK: - "- item" / "• item" on their own lines

    private static func bulletChoices(in text: String) -> [ReplyChoice] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var out: [ReplyChoice] = []
        for line in lines {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard let first = raw.first, "-*•".contains(first) else { continue }
            // "- " with a space: a bare hyphen inside prose ("Market - 200 m")
            // is not a bullet, and a line has to start with it.
            let rest = raw.dropFirst()
            guard rest.first == " " else { continue }
            let label = clean(String(rest))
            guard !label.isEmpty else { continue }
            out.append(ReplyChoice(key: "\(out.count + 1)", label: label))
        }
        return out
    }

    // MARK: - "A) item", "1. item", "(a) item"

    /// One marker occurrence: where it is, and what it called itself.
    private struct Marker {
        let key: String
        let range: Range<String.Index>
    }

    private static func markerChoices(in text: String) -> [ReplyChoice] {
        let markers = findMarkers(in: text)
        guard markers.count >= 2, isAscending(markers) else { return [] }

        var out: [ReplyChoice] = []
        for (index, marker) in markers.enumerated() {
            let start = marker.range.upperBound
            let end = index + 1 < markers.count
                ? markers[index + 1].range.lowerBound
                : text.endIndex
            guard start < end else { continue }
            var body = String(text[start..<end])

            // The last option runs into whatever sentence follows it:
            // "D) Perth. What's your guess?" - keep only up to the first
            // sentence break.
            if index == markers.count - 1,
               let stop = body.firstIndex(where: { ".?!\n".contains($0) }) {
                body = String(body[body.startIndex..<stop])
            }

            let label = clean(body)
            guard !label.isEmpty else { return [] }
            out.append(ReplyChoice(key: marker.key, label: label))
        }
        return out
    }

    private static func findMarkers(in text: String) -> [Marker] {
        var markers: [Marker] = []
        let chars = Array(text)
        let indices = Array(text.indices)

        for position in 0..<chars.count {
            // A marker is <letter-or-digit><) or .> preceded by the start of
            // the text, whitespace, or an opening bracket.
            let char = chars[position]
            guard char.isLetter || char.isNumber else { continue }
            guard position + 1 < chars.count,
                  chars[position + 1] == ")" || chars[position + 1] == "." else {
                continue
            }
            // Single-character keys only: "12) " is a numbered list item but
            // "2024. " is a year, and letters are never multi-character here.
            var startIndex = position
            if position > 0 {
                let previous = chars[position - 1]
                let opensBracket = previous == "("
                guard previous.isWhitespace || opensBracket else { continue }
                if opensBracket { startIndex = position - 1 }
            }
            // Must be followed by a space then some text.
            let afterMarker = position + 2
            guard afterMarker < chars.count, chars[afterMarker] == " " else {
                continue
            }
            guard char.isNumber || char.isLetter else { continue }

            markers.append(Marker(
                key: String(char).uppercased(),
                range: indices[startIndex]..<indices[afterMarker]
            ))
        }
        return markers
    }

    /// A, B, C… or 1, 2, 3… - anything else is prose that happens to
    /// contain a bracket.
    private static func isAscending(_ markers: [Marker]) -> Bool {
        let keys = markers.map(\.key)
        guard let first = keys.first else { return false }

        if first == "A" || first == "1" {
            // Fall through to the step check below.
        } else {
            return false
        }

        for (index, key) in keys.enumerated() {
            let expected: String
            if first == "1" {
                expected = String(index + 1)
            } else {
                guard let scalar = UnicodeScalar(65 + index) else { return false }
                expected = String(Character(scalar))
            }
            if key != expected { return false }
        }
        return true
    }

    // MARK: - Tidy up

    private static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Peel separators until nothing changes: stripping a trailing " or"
        // exposes the comma that was hiding behind it.
        var changed = true
        while changed {
            changed = false
            let before = text

            while let last = text.last, ",;:.".contains(last) {
                text.removeLast()
            }
            while let first = text.first, "([".contains(first) {
                text.removeFirst()
            }
            for joiner in ["or ", "and "] where text.lowercased().hasPrefix(joiner) {
                text.removeFirst(joiner.count)
            }
            if text.lowercased().hasSuffix(" or") {
                text.removeLast(3)
            }
            if text.lowercased().hasSuffix(" and") {
                text.removeLast(4)
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != before { changed = true }
        }
        return text
    }
}

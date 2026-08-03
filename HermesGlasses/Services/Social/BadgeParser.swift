//
// BadgeParser.swift
//
// OCR lines off a name tag -> a structured Badge. Pure Foundation, tested
// standalone in tests/badge/.
//
// Deliberately conservative: it returns nil rather than guess. An unnamed
// sighting is honest; a confidently wrong name attached to someone's face
// is not, and there is no way for the wearer to notice the mistake in the
// moment.
//
// Also home to `merge`, which combines a detected badge's barcode and OCR
// passes into one `Badge` - it lives here rather than in BadgeReader.swift
// because it touches nothing but Badge/BadgeParser/[String] and this file,
// unlike BadgeReader.swift, compiles standalone (no UIKit/Vision) for
// tests/badge/main.swift's plain-swiftc suite. That is the only reason it
// is testable at all.
//

import CoreGraphics
import Foundation

enum BadgeParser {
    /// Dropped from the front of a name line. Matched with and without the
    /// trailing dot, since OCR loses it about half the time.
    static let honorifics: Set<String> = [
        "dr", "dr.", "mr", "mr.", "ms", "ms.", "mrs", "mrs.", "prof",
        "prof.", "professor", "sir", "dame", "miss",
    ]

    /// A line containing one of these is an organisation, not a person.
    /// Doubles as a guard so "Auckland City Hospital" is never read as a
    /// three-token name.
    static let orgKeywords: Set<String> = [
        "ltd", "limited", "inc", "llc", "gmbh", "plc", "pty", "corp",
        "corporation", "company", "co", "university", "hospital", "lab",
        "labs", "laboratory", "laboratories", "group", "institute",
        "college", "school", "centre", "center", "clinic", "foundation",
        "society", "trust", "council", "department",
    ]

    /// Parse recognised lines into a badge, or nil when nothing looks like
    /// a person's name.
    static func parse(_ lines: [String], source: Badge.Source) -> Badge? {
        var remaining = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isUsable)
        guard !remaining.isEmpty else { return nil }

        guard let nameIndex = remaining.firstIndex(where: looksLikeName)
        else { return nil }
        let name = displayName(remaining.remove(at: nameIndex))

        var org: String?
        if let orgIndex = remaining.firstIndex(where: looksLikeOrg) {
            org = titleCasedIfShouting(remaining.remove(at: orgIndex))
        } else if remaining.count > 1 {
            // No keyword to go on: the bottom line of a badge is the
            // employer far more often than it is a job title.
            org = titleCasedIfShouting(remaining.removeLast())
        }

        let title = remaining.first.map(titleCasedIfShouting)

        return Badge(
            name: name, title: title, org: org, rawLines: lines, source: source
        )
    }

    /// Merge one detected badge's barcode and OCR passes into a single
    /// `Badge`, plus the kind and location the detector already determined.
    /// Pure - no Vision, no image work - so this is the one piece of
    /// `BadgeReader.readDetected`'s logic that can be exercised without a
    /// device. See `BadgeReader.readDetected` for where `barcode`/`lines`
    /// come from.
    ///
    /// A decoded barcode outranks OCR because it decoded rather than
    /// inferred: where both name someone, the barcode wins and `title`/`org`
    /// fall back to OCR only where the barcode itself lacks them. Where the
    /// barcode named nobody (or there wasn't one), OCR fills the gap, and an
    /// unnamed barcode's payload still rides along on the OCR badge. When
    /// neither pass reads anything, the badge is still returned NON-NIL -
    /// located but unreadable - so `kind`/`badgeRect` survive and badge
    /// assist can still find it via `badge?.name == nil`, never `badge ==
    /// nil`.
    static func merge(
        barcode: Badge?, lines: [String], kind: Badge.Kind?, rect: CGRect
    ) -> Badge {
        let text = parse(lines, source: .onDevice)
        var badge: Badge
        if let barcode, barcode.name != nil {
            badge = barcode
            badge.title = barcode.title ?? text?.title
            badge.org = barcode.org ?? text?.org
            badge.rawLines = lines.isEmpty ? barcode.rawLines : lines
        } else if var text {
            text.barcodePayload = barcode?.barcodePayload
            badge = text
        } else {
            // Located but unreadable. Still a badge, still worth a record.
            badge = Badge(
                rawLines: lines, source: .onDevice,
                barcodePayload: barcode?.barcodePayload
            )
        }

        badge.kind = kind
        badge.badgeRect = rect
        return badge
    }

    // MARK: - Line predicates

    /// Real content: two or more characters, at least one of them a letter.
    static func isUsable(_ line: String) -> Bool {
        line.count >= 2 && line.contains(where: \.isLetter)
    }

    /// One to four capitalised tokens, no digits, and not an organisation.
    static func looksLikeName(_ line: String) -> Bool {
        guard !line.contains(where: \.isNumber), !looksLikeOrg(line) else {
            return false
        }
        let tokens = nameTokens(line)
        guard (1...4).contains(tokens.count) else { return false }
        return tokens.allSatisfy { $0.first?.isUppercase == true }
    }

    static func looksLikeOrg(_ line: String) -> Bool {
        let words = line.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return words.contains(where: orgKeywords.contains)
    }

    // MARK: - Formatting

    /// The line's tokens with honorifics removed.
    static func nameTokens(_ line: String) -> [String] {
        line.split(separator: " ")
            .map(String.init)
            .filter { !honorifics.contains($0.lowercased()) }
    }

    static func displayName(_ line: String) -> String {
        titleCasedIfShouting(nameTokens(line).joined(separator: " "))
    }

    /// Badges shout. A line whose every letter is uppercase is title-cased
    /// for display; anything mixed-case is left exactly as printed.
    static func titleCasedIfShouting(_ line: String) -> String {
        let letters = line.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isUppercase) else {
            return line
        }
        return line.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

/// The opt-in AI fallback for badges Vision could not read.
///
/// Runs only AFTER the encounter is on disk, and is bounded because it is
/// the one part of this feature that costs money: sequential, capped, timed
/// out, and abandoned wholesale the moment the provider says the key is bad
/// rather than repeating that answer five more times.
enum BadgeAssist {
    static let maxReads = 6
    static let timeout: TimeInterval = 20

    /// Bounds on what a single reply may contribute. The lines survive into
    /// `Badge.rawLines`, which is persisted in `encounters.json` (rewritten
    /// whole on every mutation) and rendered line-by-line on the sighting
    /// screen. The text is both model-generated and printed by whoever made
    /// the badge, so an unbounded reply is a storage and display problem,
    /// not merely noise. A real badge is a handful of short lines.
    static let maxReplyLines = 8
    static let maxLineLength = 120

    static let systemPrompt = """
        You read name badges from photographs. Reply with only the lines of \
        text printed on the badge, one per line. Add no commentary.
        """

    static let userText = """
        Read the name badge or name tag worn by the person in this photo. \
        Reply with the lines of text printed on the badge, one per line, and \
        nothing else. If there is no badge, reply NONE.
        """

    /// Turn a provider reply into a badge. Goes through the SAME
    /// `BadgeParser` as the on-device path, so there is one parsing story
    /// and prose like "I can't see a badge" falls out as nil on its own.
    static func parse(_ reply: String) -> Badge? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.uppercased() != "NONE" else { return nil }
        let lines = trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxReplyLines)
            .map { String($0.prefix(maxLineLength)) }
        return BadgeParser.parse(lines, source: .assisted)
    }

    /// True when the failure means "stop the whole pass", not "this one
    /// photo failed". Repeating a rejected key six times helps nobody.
    static func isFatal(_ error: Error) -> Bool {
        guard let providerError = error as? AIProviderError else { return false }
        switch providerError {
        case .missingKey, .invalidURL:
            return true
        case .http(let status, _):
            return status == 401 || status == 403
        case .badResponse:
            return false
        }
    }
}

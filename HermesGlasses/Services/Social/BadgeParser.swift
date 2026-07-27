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

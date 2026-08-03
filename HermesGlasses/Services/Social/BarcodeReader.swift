//
// BarcodeReader.swift
//
// The one part of badge reading that does not guess. Conference tags very
// often carry a QR encoding a vCard or a MECARD; those decode to a name
// exactly, where OCR infers one from line shapes. That is why a barcode
// badge outranks an on-device text read in Badge.Source.
//
// The parser is pure and takes a String, so tests/badge exercises it
// without Vision. The reader takes a CGImage, not a UIImage, so this file
// compiles on macOS for the standalone suites.
//

import CoreGraphics
import Foundation
import Vision
import os

enum BarcodeReader {
    private static let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "badge"
    )

    /// A QR can hold kilobytes. `barcodePayload` is persisted in
    /// encounters.json (rewritten whole on every mutation) and shown on the
    /// sighting screen, so an unbounded payload is a storage and display
    /// problem, not merely noise. Same reasoning as BadgeAssist's bounds.
    static let maxPayloadLength = 512

    /// Read any barcode in the image and turn it into a badge. Synchronous:
    /// the caller is responsible for being off the main actor.
    static func read(_ image: CGImage) -> Badge? {
        let request = VNDetectBarcodesRequest()
        // Badges carry QR (conference), Code128 and PDF417 (corporate and
        // government ID). Leaving the symbologies at their default would
        // also work; naming them keeps the scan cheap.
        request.symbologies = [.qr, .code128, .pdf417, .dataMatrix, .aztec]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("barcode request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // A badge can carry more than one barcode at once - a QR vCard
        // next to a Code128 check-in id is common. Vision does not
        // guarantee `results` order, so collect every candidate and let
        // `preferred` pick, instead of returning whichever parsed first.
        let candidates = (request.results ?? []).compactMap { observation in
            observation.payloadStringValue.flatMap(parse)
        }
        return preferred(candidates)
    }

    /// Among several decoded badges, prefer one that actually named
    /// someone; fall back to the first parseable badge when none did.
    /// `parse` returns SOME badge for almost any non-empty payload (an
    /// opaque id still counts), so "first parseable" alone can't tell a
    /// vCard from a check-in barcode when Vision lists the id first.
    /// Not private: a CGImage carrying two real barcodes isn't practical
    /// to construct in the standalone `swiftc` suite, so tests/badge
    /// exercises this helper directly instead of `read`.
    static func preferred(_ badges: [Badge]) -> Badge? {
        badges.first(where: { $0.name != nil }) ?? badges.first
    }

    /// A decoded payload -> a badge. Returns a badge with no name for an
    /// opaque id: the tag genuinely carries that string, and keeping it
    /// leaves a trail when the name has to come from somewhere else.
    static func parse(_ payload: String) -> Badge? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let kept = String(trimmed.prefix(maxPayloadLength))

        if let card = parseVCard(trimmed) ?? parseMECard(trimmed) {
            return Badge(
                name: card.name, title: card.title, org: card.org,
                rawLines: [kept], source: .barcode, barcodePayload: kept
            )
        }
        return Badge(rawLines: [kept], source: .barcode, barcodePayload: kept)
    }

    // MARK: - Encodings

    private struct Card {
        var name: String?
        var title: String?
        var org: String?
    }

    /// BEGIN:VCARD … FN / TITLE / ORG … END:VCARD
    private static func parseVCard(_ payload: String) -> Card? {
        guard payload.uppercased().contains("BEGIN:VCARD") else { return nil }
        var card = Card()
        for rawLine in payload.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // A property may carry parameters: FN;CHARSET=UTF-8:Sarah Chen
            guard let colon = line.firstIndex(of: ":") else { continue }
            let property = line[line.startIndex..<colon]
                .split(separator: ";").first.map(String.init)?.uppercased()
            let rawValue = String(line[line.index(after: colon)...])
            switch property {
            case "FN":
                let value = unescape(rawValue).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                card.name = value
            case "TITLE":
                let value = unescape(rawValue).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                card.title = value
            case "ORG":
                // ORG is structured: "Hospital;Radiology". Split on an
                // UNESCAPED semicolon FIRST, then unescape the surviving
                // component. Unescaping before splitting would turn an
                // escaped "\;" into a real semicolon and shear the value
                // right at the point the escape was protecting.
                guard let first = splitUnescaped(rawValue, on: ";").first else { continue }
                let value = unescape(first).trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                card.org = value
            default: continue
            }
        }
        return card.name == nil && card.org == nil ? nil : card
    }

    /// MECARD:N:Last,First;ORG:…;;
    private static func parseMECard(_ payload: String) -> Card? {
        guard payload.uppercased().hasPrefix("MECARD:") else { return nil }
        let body = String(payload.dropFirst("MECARD:".count))
        var card = Card()
        // Split the whole body on UNESCAPED semicolons first: a field
        // whose value contains "\;" must stay one field, not get sheared
        // into two fragments that both fail the colon check below and
        // are silently dropped.
        for field in splitUnescaped(body, on: ";") {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = field[field.startIndex..<colon].uppercased()
            let rawValue = String(field[field.index(after: colon)...])
            let value = unescape(rawValue).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "N":
                // MECARD names are "Last,First".
                let parts = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                card.name = parts.count >= 2
                    ? "\(parts[1]) \(parts[0])" : value
            case "ORG": card.org = value
            case "TITLE": card.title = value
            default: continue
            }
        }
        return card.name == nil && card.org == nil ? nil : card
    }

    /// Splits `text` on `separator`, treating a separator preceded by an
    /// unescaped backslash as literal - not a split point. Escapes are
    /// left untouched in the returned pieces; callers run `unescape`
    /// afterwards. This has to run BEFORE unescaping: unescaping first
    /// would turn an escaped delimiter into a real one before the
    /// splitter ever saw the difference.
    private static func splitUnescaped(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for char in text {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                current.append(char)
                escaped = true
            } else if char == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }

    /// vCard/MECARD escaping: `\,` `\;` `\\` unescape to their plain
    /// character; `\n` / `\N` (a folded newline inside a value) unescapes
    /// to a space. A single left-to-right pass over the characters -
    /// rather than four chained global replacements - is required: doing
    /// `\n` -> " " as its own pass would misread the "n" in an escaped
    /// backslash ("\\n": a literal backslash followed by a literal "n")
    /// as if it were an escaped newline.
    private static func unescape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var chars = value.makeIterator()
        while let char = chars.next() {
            guard char == "\\" else {
                result.append(char)
                continue
            }
            guard let next = chars.next() else {
                // A trailing lone backslash: nothing to escape, keep it.
                result.append(char)
                break
            }
            switch next {
            case "n", "N": result.append(" ")
            case ",": result.append(",")
            case ";": result.append(";")
            case "\\": result.append("\\")
            default:
                // An unrecognised escape: keep both characters verbatim
                // rather than silently dropping the backslash.
                result.append(char)
                result.append(next)
            }
        }
        return result
    }
}

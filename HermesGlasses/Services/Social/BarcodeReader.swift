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

        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue,
                  let badge = parse(payload) else { continue }
            return badge
        }
        return nil
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
            let value = unescape(String(line[line.index(after: colon)...]))
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch property {
            case "FN": card.name = value
            case "TITLE": card.title = value
            case "ORG":
                // ORG is structured: "Hospital;Radiology". The first
                // component is the organisation.
                card.org = value.split(separator: ";").first.map(String.init)
            default: continue
            }
        }
        return card.name == nil && card.org == nil ? nil : card
    }

    /// MECARD:N:Last,First;ORG:…;;
    private static func parseMECard(_ payload: String) -> Card? {
        guard payload.uppercased().hasPrefix("MECARD:") else { return nil }
        let body = payload.dropFirst("MECARD:".count)
        var card = Card()
        for field in body.split(separator: ";") {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = field[field.startIndex..<colon].uppercased()
            let value = unescape(String(field[field.index(after: colon)...]))
                .trimmingCharacters(in: .whitespaces)
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

    /// vCard escapes commas, semicolons and newlines in values.
    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

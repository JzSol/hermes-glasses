//
// BadgePortrait.swift
//
// The photograph printed on an ID card, cropped out of a located badge.
//
// This is the one payload in badge reading that a person would object to on
// sight, so it is gated by its OWN setting (badge_portraits_enabled,
// default off) rather than riding on badge OCR, it never leaves the phone,
// and it is explicitly excluded from the BadgeAssist payload.
//
// It is NOT an identity key. Grouping is by badge text; there is no face
// recognition in this app and this must not become the start of one.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import os

enum BadgePortrait {
    private static let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "badge"
    )

    /// A face smaller than this fraction of the badge is not the printed
    /// portrait - it is noise, or a face behind the badge.
    static let minimumFaceFraction: CGFloat = 0.04

    /// Padding around the detected face, as a fraction of its own size. An
    /// ID portrait includes shoulders and a border; a tight face box looks
    /// like a crop of a crop.
    static let padding: CGFloat = 0.25

    static let jpegQuality: CGFloat = 0.8

    /// The portrait printed on this badge, as JPEG data. Nil when there is
    /// no face on the badge - which is every conference lanyard, so nil is
    /// the common answer and not a failure. Synchronous: the caller is
    /// responsible for being off the main actor.
    static func extract(from badgeCrop: CGImage) -> Data? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: badgeCrop, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("face request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let faces = request.results ?? []
        // The printed portrait is the largest face inside the badge.
        guard let largest = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        let area = largest.boundingBox.width * largest.boundingBox.height
        guard area >= minimumFaceFraction else { return nil }

        // Vision is bottom-left; BadgeCrop is where that flip lives.
        guard let box = BadgeCrop.box(
            label: "face", confidence: 1, visionRect: largest.boundingBox
        ) else { return nil }

        let padded = box.rect.insetBy(
            dx: -box.rect.width * padding, dy: -box.rect.height * padding
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        let size = CGSize(width: badgeCrop.width, height: badgeCrop.height)
        guard let pixels = BadgeCrop.pixelRect(for: padded, in: size),
              let cropped = badgeCrop.cropping(to: pixels)
        else { return nil }

        return jpeg(cropped)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

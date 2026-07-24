//
// LensPDFRenderer.swift
//
// Renders a Lens object log to a one-row-per-object PDF for sharing
// (WhatsApp etc). UIKit's UIGraphicsPDFRenderer; US Letter, paginated.
//

import UIKit

enum LensPDFRenderer {
    struct Row {
        let label: String
        let totalLookTime: TimeInterval
        let lookCount: Int
        let image: UIImage?
    }

    /// "14.2s" under a minute, "1m 04s" at or above.
    static func timeLabel(_ t: TimeInterval) -> String {
        if t < 60 { return String(format: "%.1fs", t) }
        let minutes = Int(t) / 60, seconds = Int(t) % 60
        return String(format: "%dm %02ds", minutes, seconds)
    }

    static func makePDF(title: String, rows: [Row]) -> Data {
        let pageWidth: CGFloat = 612, pageHeight: CGFloat = 792
        let margin: CGFloat = 40
        let rowHeight: CGFloat = 84
        let thumb: CGFloat = 64
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = margin

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 22)
            ]
            (title as NSString).draw(
                at: CGPoint(x: margin, y: y), withAttributes: titleAttrs
            )
            y += 40

            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 16)
            ]
            let metaAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.darkGray
            ]

            for row in rows {
                if y + rowHeight > pageHeight - margin {
                    ctx.beginPage()
                    y = margin
                }
                let thumbRect = CGRect(x: margin, y: y, width: thumb, height: thumb)
                if let image = row.image {
                    image.draw(in: aspectFit(image.size, into: thumbRect))
                } else {
                    UIColor.systemGray5.setFill()
                    UIBezierPath(roundedRect: thumbRect, cornerRadius: 8).fill()
                }
                let textX = margin + thumb + 16
                (row.label as NSString).draw(
                    at: CGPoint(x: textX, y: y + 8), withAttributes: nameAttrs
                )
                let looks = "\(row.lookCount) look\(row.lookCount == 1 ? "" : "s")"
                let meta = "\(timeLabel(row.totalLookTime))   ·   \(looks)"
                (meta as NSString).draw(
                    at: CGPoint(x: textX, y: y + 34), withAttributes: metaAttrs
                )
                y += rowHeight
            }
        }
    }

    /// Center-fit `size` inside `rect` preserving aspect ratio.
    private static func aspectFit(_ size: CGSize, into rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(
            x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h
        )
    }
}

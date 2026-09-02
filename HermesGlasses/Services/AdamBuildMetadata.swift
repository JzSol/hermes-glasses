//
// AdamBuildMetadata.swift
//
// Foundation-only display logic for the Adam build footer. The timestamp is
// read from the Info.plist inside the running app bundle, so it describes the
// built artifact and remains stable between launches.
//

import Foundation

enum AdamBuildMetadata {
    static let relativeAgeThreshold: TimeInterval = 24 * 60 * 60

    /// The built app's Info.plist modification date is written into the
    /// artifact by the build, unlike a launch-time date which would drift.
    static func artifactTimestamp(in bundle: Bundle = .main) -> Date? {
        let infoURL = bundle.bundleURL.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }
        return try? infoURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
    }

    static func updateLabel(
        for buildDate: Date?,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard let buildDate,
              buildDate.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              buildDate <= now else {
            return NSLocalizedString(
                "Update date unavailable",
                comment: "Fallback when the Adam artifact timestamp is absent or invalid"
            )
        }

        let age = now.timeIntervalSince(buildDate)
        if age < relativeAgeThreshold {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            // The template intentionally contains no seconds or timezone.
            formatter.setLocalizedDateFormatFromTemplate("yMMMdjm")
            let dateTime = formatter.string(from: buildDate)
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "Updated %@",
                    comment: "Fresh Adam build timestamp"
                ),
                dateTime
            )
        }

        let days = max(1, Int(age / relativeAgeThreshold))
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        let relativeAge = relativeFormatter.localizedString(
            from: DateComponents(day: -days)
        )
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "Updated %@",
                comment: "Relative Adam build age"
            ),
            relativeAge
        )
    }
}

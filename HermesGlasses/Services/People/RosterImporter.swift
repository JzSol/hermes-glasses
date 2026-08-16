//
// RosterImporter.swift
//
// Turns a folder of portraits into people. Three tiers, so the roster that
// exists today (45 flat `<Name>.jpg` files, no metadata) works untouched
// while richer forms layer on:
//
//   <Name>.jpg      -> one person, one photo
//   <Name>/*.jpg    -> one person, every image inside
//   people.json     -> merged BY NAME onto the above; adds org/title/notes
//                      and may list photos explicitly
//
// Names are the filename stem VERBATIM. "Malsha de Zoysa", "Sahan H" and
// "anjana viduranga" are all real entries and all correct as written. Any
// tidying - title case, initial expansion, separator splitting - would
// damage real names to no benefit.
//
// THIS FILE IS PURE: Foundation only, no filesystem, no UIKit, no Vision,
// so the whole planning pass is testable in tests/roster/ without a device.
// The half that reads bytes and embeds faces lives in
// RosterImporter+Import.swift - keep it there.
//

import Foundation

/// A person the walk decided exists, before any bytes are read.
struct PlannedPerson: Equatable {
    var name: String
    /// Paths relative to the roster folder, sorted.
    var relativePaths: [String]
    var org: String?
    var title: String?
    var notes: String?
}

enum RosterImporter {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]

    /// Is this relative path an image the importer will read? Dotfiles are
    /// excluded outright - `.DS_Store` and resource forks are not portraits,
    /// and one of them turning into a person is the kind of thing nobody
    /// notices until the roster screen looks wrong.
    static func isSupportedImage(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        return supportedExtensions.contains(
            (name as NSString).pathExtension.lowercased()
        )
    }

    /// The pure planning pass. `files` are paths relative to the roster
    /// folder, using "/" for nesting; `details` is a parsed people.json.
    /// Order-independent: the result is sorted by name.
    static func plan(files: [String], details: [RosterDetails]) -> [PlannedPerson] {
        // Photos a details entry claims explicitly are spoken for, and must
        // not also become people in their own right.
        let claimed = Set(details.flatMap { $0.photos ?? [] })

        var photosByName: [String: [String]] = [:]
        for path in files.sorted() where isSupportedImage(path) {
            guard !claimed.contains(path) else { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            let name: String
            if parts.count >= 2 {
                // Nested: the FIRST path component is the person.
                name = String(first)
            } else {
                // `String(...)` is load-bearing - `first` is a Substring and
                // does not bridge to NSString on its own.
                name = (String(first) as NSString).deletingPathExtension
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            photosByName[trimmed, default: []].append(path)
        }

        var byName: [String: PlannedPerson] = [:]
        for (name, paths) in photosByName {
            byName[name] = PlannedPerson(
                name: name, relativePaths: paths.sorted(),
                org: nil, title: nil, notes: nil
            )
        }

        for entry in details {
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // An entry matching no photo still becomes a person, with no
            // photos and therefore no chance of a face match. A typo'd name
            // has to be VISIBLE in the roster; dropping it silently is how
            // someone spends the conference wondering why one person never
            // resolves.
            var person = byName[name]
                ?? PlannedPerson(name: name, relativePaths: [],
                                 org: nil, title: nil, notes: nil)
            person.org = entry.org
            person.title = entry.title
            person.notes = entry.notes
            if let photos = entry.photos, !photos.isEmpty {
                person.relativePaths = photos.filter(isSupportedImage).sorted()
            }
            byName[name] = person
        }

        return byName.values.sorted { $0.name < $1.name }
    }
}

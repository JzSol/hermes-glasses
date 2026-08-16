//
// RosterImporter+Import.swift
//
// The half of the importer that touches bytes: walk the folder, read the
// photos, embed the faces, replace the roster. Kept apart from
// RosterImporter.swift so the planning pass stays Foundation-only and
// testable in tests/roster/ without a device.
//
// An import is all-or-nothing by construction: the store is only touched
// once every person is built, so a failure part-way leaves the previous
// roster intact.
//

import Foundation
import UIKit

/// What an import actually did. Shown to the user, not logged and
/// forgotten: a portrait with no findable face is a person who can never be
/// recognised, and that has to be visible before the conference rather than
/// discovered during it.
struct RosterImportReport {
    var people: Int = 0
    var photos: Int = 0
    /// Photos that yielded a usable face - an embedding when a model is
    /// bundled, a detection when one is not.
    var facesFound: Int = 0
    /// Names whose every portrait failed. These people cannot be matched.
    var peopleWithoutFace: [String] = []
    var errors: [String] = []

    var isEmpty: Bool { people == 0 && errors.isEmpty }
}

extension RosterImporter {
    /// Walk `folder`, build people, embed their portraits, and replace the
    /// roster.
    ///
    /// Security-scoped access is the CALLER's to hold: SwiftUI's
    /// `.fileImporter` hands back a scoped URL, and the scope must cover
    /// every read inside here, not just the open.
    ///
    /// `embedder` is nil when no model is bundled. Import still works -
    /// people and photos land, and coverage is still counted by face
    /// detection - so the roster can be prepared before the recogniser
    /// exists. Nobody is matchable until it does.
    static func importRoster(
        from folder: URL, into store: RosterStore, embedder: FaceEmbedder?
    ) async -> RosterImportReport {
        var report = RosterImportReport()

        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            report.errors.append("Could not read that folder.")
            return report
        }

        var relativePaths: [String] = []
        var detailsJSON: Data?
        let base = folder.standardizedFileURL.path
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            var relative = String(path.dropFirst(base.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            guard !relative.isEmpty else { continue }
            if (relative as NSString).lastPathComponent == "people.json" {
                detailsJSON = try? Data(contentsOf: url)
                continue
            }
            relativePaths.append(relative)
        }

        var details: [RosterDetails] = []
        if let detailsJSON {
            do {
                details = try JSONDecoder().decode([RosterDetails].self, from: detailsJSON)
            } catch {
                report.errors.append(
                    "people.json could not be read: \(error.localizedDescription)"
                )
            }
        }

        let planned = plan(files: relativePaths, details: details)
        guard !planned.isEmpty else {
            report.errors.append("No images found in that folder.")
            return report
        }

        var people: [RosterPerson] = []
        var photos: [String: Data] = [:]

        for entry in planned {
            let personID = UUID()
            var filenames: [String] = []
            var embeddings: [[Float]] = []
            var sawAFace = false

            for (index, relative) in entry.relativePaths.enumerated() {
                let source = folder.appendingPathComponent(relative)
                guard let data = try? Data(contentsOf: source),
                      let image = UIImage(data: data) else {
                    report.errors.append("Unreadable: \(relative)")
                    continue
                }
                let ext = (relative as NSString).pathExtension.lowercased()
                let filename = "\(personID.uuidString)-\(index)."
                    + (ext.isEmpty ? "jpg" : ext)
                filenames.append(filename)
                photos[filename] = data
                report.photos += 1

                if let embedder {
                    if let vector = await embedder.embed(image) {
                        embeddings.append(vector)
                        sawAFace = true
                        report.facesFound += 1
                    }
                } else if await FaceEmbedder.hasDetectableFace(image) {
                    // No model yet: still count coverage, so the report is
                    // useful before the recogniser lands.
                    sawAFace = true
                    report.facesFound += 1
                }
            }

            if !filenames.isEmpty && !sawAFace {
                report.peopleWithoutFace.append(entry.name)
            }

            people.append(RosterPerson(
                id: personID, name: entry.name, org: entry.org,
                title: entry.title, notes: entry.notes,
                photoFilenames: filenames, embeddings: embeddings,
                modelID: embedder?.modelID
            ))
        }

        report.people = people.count
        store.replaceAll(people, photos: photos)
        return report
    }
}

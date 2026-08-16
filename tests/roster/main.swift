//
// Standalone tests for RosterImporter's planning half. No XCTest target:
//   xcrun swiftc \
//     HermesGlasses/Services/People/RosterPerson.swift \
//     HermesGlasses/Services/People/RosterImporter.swift \
//     tests/roster/main.swift -o /tmp/roster-tests && /tmp/roster-tests
//
// plan() turns a flat list of relative paths (plus an optional people.json)
// into people. It never touches the filesystem, so every shape of roster
// folder can be pinned here - including the one that actually exists today:
// 45 flat "<Full Name>.jpg" files with no metadata at all.
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}

func person(_ people: [PlannedPerson], _ name: String) -> PlannedPerson? {
    people.first { $0.name == name }
}

// MARK: - Flat files: the roster as it exists today

var people = RosterImporter.plan(
    files: ["Prasanth Sasikumar.jpg", "Ryo Hajika.jpg", "Malsha de Zoysa.jpg"],
    details: []
)
expect(people.count == 3, "three flat files make three people")
expect(person(people, "Malsha de Zoysa")?.relativePaths == ["Malsha de Zoysa.jpg"],
       "a flat file's stem is the name, verbatim")
expect(person(people, "Sahan H") == nil, "no person invented")

// Names are preserved exactly - no title-casing, no initial expansion. All
// three of these are real entries in the roster.
people = RosterImporter.plan(files: ["anjana viduranga.jpg", "Sahan H.jpg"], details: [])
expect(person(people, "anjana viduranga") != nil, "lowercase names are left alone")
expect(person(people, "Sahan H") != nil, "a trailing initial is left alone")

// MARK: - Subfolders carry several photos for one person

people = RosterImporter.plan(
    files: ["Ryo Hajika/1.jpg", "Ryo Hajika/2.jpg", "Ryo Hajika/3.png"],
    details: []
)
expect(people.count == 1, "a subfolder is one person")
expect(people.first?.name == "Ryo Hajika", "the folder name is the person's name")
expect(people.first?.relativePaths.count == 3, "every image inside belongs to them")
expect(people.first?.relativePaths == ["Ryo Hajika/1.jpg", "Ryo Hajika/2.jpg", "Ryo Hajika/3.png"],
       "photo order is stable (sorted)")

// MARK: - Flat and nested mixed in one folder

people = RosterImporter.plan(
    files: ["Ryo Hajika/1.jpg", "Ryo Hajika/2.jpg", "Prasanth Sasikumar.jpg"],
    details: []
)
expect(people.count == 2, "flat and nested coexist")
expect(person(people, "Ryo Hajika")?.relativePaths.count == 2, "nested keeps both photos")
expect(person(people, "Prasanth Sasikumar")?.relativePaths.count == 1, "flat keeps its one")

// A flat file AND a subfolder for the same name collapse to one person.
people = RosterImporter.plan(
    files: ["Ryo Hajika.jpg", "Ryo Hajika/2.jpg"], details: []
)
expect(people.count == 1, "same name flat + nested is still one person")
expect(people.first?.relativePaths.count == 2, "and keeps both photos")

// MARK: - Non-images are ignored

people = RosterImporter.plan(
    files: ["Ryo Hajika.jpg", "people.json", ".DS_Store", "notes.txt", "Ryo Hajika.HEIC"],
    details: []
)
expect(people.count == 1, "only images make people")
expect(person(people, "Ryo Hajika")?.relativePaths.count == 2,
       "extension matching is case-insensitive (.jpg + .HEIC)")
expect(person(people, "people") == nil, "people.json is not a person")
expect(person(people, ".DS_Store") == nil, "dotfiles are not people")

expect(RosterImporter.isSupportedImage("a.JPEG"), "JPEG accepted")
expect(RosterImporter.isSupportedImage("a.heic"), "heic accepted")
expect(!RosterImporter.isSupportedImage("a.txt"), "txt rejected")
expect(!RosterImporter.isSupportedImage(".hidden.jpg"), "dotfiles rejected")
expect(RosterImporter.isSupportedImage("Ryo Hajika/1.jpg"), "nested paths are matched on their leaf")

// MARK: - people.json merges by name

people = RosterImporter.plan(
    files: ["Ryo Hajika.jpg", "Prasanth Sasikumar.jpg"],
    details: [
        RosterDetails(name: "Ryo Hajika", org: "Empathic Computing Lab",
                      title: "PhD Candidate", notes: "Met at ISMAR", photos: nil)
    ]
)
expect(person(people, "Ryo Hajika")?.org == "Empathic Computing Lab",
       "details merge onto the matching person")
expect(person(people, "Ryo Hajika")?.relativePaths == ["Ryo Hajika.jpg"],
       "details with no photos keep the photos found on disk")
expect(person(people, "Prasanth Sasikumar")?.org == nil,
       "people without a details entry are untouched")

// An explicit photo list overrides what the walk found.
people = RosterImporter.plan(
    files: ["ryo-1.jpg", "ryo-2.jpg"],
    details: [RosterDetails(name: "Ryo Hajika", org: nil, title: nil, notes: nil,
                            photos: ["ryo-1.jpg", "ryo-2.jpg"])]
)
expect(person(people, "Ryo Hajika")?.relativePaths == ["ryo-1.jpg", "ryo-2.jpg"],
       "an explicit photo list names the person's photos")
expect(person(people, "ryo-1") == nil,
       "photos claimed by a details entry stop being people of their own")

// A details entry matching nothing is still imported, with no photos - a
// typo'd name must be visible in the roster, not silently dropped.
people = RosterImporter.plan(
    files: ["Ryo Hajika.jpg"],
    details: [RosterDetails(name: "Ryo Hajkia", org: "typo", title: nil,
                            notes: nil, photos: nil)]
)
expect(people.count == 2, "an unmatched details entry still becomes a person")
expect(person(people, "Ryo Hajkia")?.relativePaths.isEmpty == true,
       "and has no photos, so it can never match a face")

// MARK: - Determinism

let a = RosterImporter.plan(files: ["B.jpg", "A.jpg", "C.jpg"], details: [])
let b = RosterImporter.plan(files: ["C.jpg", "B.jpg", "A.jpg"], details: [])
expect(a == b, "plan is order-independent")
expect(a.map(\.name) == ["A", "B", "C"], "people come back sorted by name")

// MARK: - RosterPerson

var subject = RosterPerson(name: "Ryo Hajika", org: "Empathic Computing Lab",
                           title: "PhD Candidate")
expect(subject.detailLine == "PhD Candidate · Empathic Computing Lab",
       "detailLine reads title, org, notes in that order (got \(subject.detailLine))")
subject = RosterPerson(name: "Sahan H")
expect(subject.detailLine.isEmpty, "a name-only person has no detail line")
expect(!subject.isMatchable, "a person with no embedding cannot be matched")
subject = RosterPerson(name: "Sahan H", embeddings: [[1, 0]])
expect(subject.isMatchable, "one embedding makes a person matchable")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

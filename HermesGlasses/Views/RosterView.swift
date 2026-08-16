//
// RosterView.swift
//
// Settings -> People roster. Import a folder of portraits, see who is in
// it, remove them all. Read-only otherwise: the source of truth is the
// folder the user maintains, and an import REPLACES rather than merges, so
// there is no in-app editing that could drift from it.
//
// The screen's real job is the import report. "45 people imported" is not
// the useful number - "and three of them have no findable face" is, because
// those three cannot be recognised no matter how good the model is, and
// there is no other moment where that fact surfaces.
//

import SwiftUI
import UniformTypeIdentifiers

struct RosterView: View {
    let store: RosterStore

    @State private var people: [RosterPerson] = []
    @State private var importing = false
    @State private var working = false
    @State private var report: RosterImportReport?
    @State private var confirmRemove = false

    private var modelAvailable: Bool { FaceEmbedder.isAvailable }

    var body: some View {
        HermesScrollPage {
            if !modelAvailable { modelCard }
            summaryCard
            if let report, !report.isEmpty { reportCard(report) }
            if people.isEmpty {
                emptyCard
            } else {
                peopleSection
            }
        }
        .navigationTitle("People roster")
        .navigationBarTitleDisplayMode(.inline)
        .task { people = store.all() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handle(result)
        }
        .confirmationDialog(
            "Remove everyone in the roster?",
            isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button("Remove all", role: .destructive) {
                store.removeAll()
                people = []
                report = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Cards

    /// Said plainly rather than hidden: without the model the roster can be
    /// prepared but nobody can be identified from it.
    private var modelCard: some View {
        HermesSection(
            header: "Face model",
            footer: "The roster imports and stores fine without it — but "
                + "Lookup cannot identify anyone until the model is bundled."
        ) {
            HermesRow(
                title: "Not installed",
                subtitle: "faceid.mlpackage is missing from the app.",
                showsChevron: false
            ) { HermesBadge(text: "Required", prominent: true) }
        }
    }

    private var summaryCard: some View {
        HermesSection(header: "Roster") {
            HermesRow("People", icon: "person.2",
                      value: "\(people.count)", showsChevron: false)
            HermesDivider()
            HermesRow("Photos", icon: "photo.on.rectangle",
                      value: "\(people.reduce(0) { $0 + $1.photoFilenames.count })",
                      showsChevron: false)
            HermesDivider()
            HermesRow("Recognisable", icon: "faceid",
                      value: "\(people.filter(\.isMatchable).count)",
                      showsChevron: false)
            HermesDivider()
            Button { importing = true } label: {
                HermesRow(
                    working ? "Importing…" : "Import folder",
                    icon: "square.and.arrow.down", showsChevron: false
                )
            }
            .buttonStyle(.plain)
            .disabled(working)
            if !people.isEmpty {
                HermesDivider()
                Button { confirmRemove = true } label: {
                    HermesRow("Remove all", icon: "trash", showsChevron: false)
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
        }
    }

    private var emptyCard: some View {
        HermesSection(
            footer: "Pick a folder of portraits named after the person — "
                + "“Jane Smith.jpg”. A subfolder per person holds several "
                + "photos of them, which matches better than one."
        ) {
            HermesRow("No roster imported",
                      icon: "person.crop.circle.badge.questionmark",
                      showsChevron: false)
        }
    }

    private func reportCard(_ report: RosterImportReport) -> some View {
        HermesSection(header: "Last import") {
            HermesRow(
                title: "Imported",
                subtitle: "\(report.people) people, \(report.photos) photos, "
                    + "\(report.facesFound) with a usable face",
                showsChevron: false
            ) { EmptyView() }
            if !report.peopleWithoutFace.isEmpty {
                HermesDivider()
                HermesRow(
                    title: "No face found",
                    subtitle: report.peopleWithoutFace.joined(separator: ", ")
                        + " — these people cannot be recognised. Replace their photo.",
                    showsChevron: false
                ) {
                    HermesBadge(text: "\(report.peopleWithoutFace.count)",
                                prominent: true)
                }
            }
            ForEach(report.errors, id: \.self) { error in
                HermesDivider()
                HermesRow(title: error, showsChevron: false) { EmptyView() }
            }
        }
    }

    private var peopleSection: some View {
        HermesSection(header: "In the roster") {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                if index > 0 { HermesDivider() }
                HermesRow(
                    title: person.name,
                    subtitle: person.detailLine.isEmpty ? nil : person.detailLine,
                    showsChevron: false
                ) {
                    if !person.isMatchable && modelAvailable {
                        HermesBadge(text: "No face")
                    }
                }
            }
        }
    }

    // MARK: - Import

    private func handle(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let folder = urls.first else {
            if case .failure(let error) = result {
                report = RosterImportReport(errors: [error.localizedDescription])
            }
            return
        }
        working = true
        Task {
            // The picker hands back a security-scoped URL, and the scope has
            // to cover every read inside the import - not just the open.
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

            let outcome = await RosterImporter.importRoster(
                from: folder, into: store, embedder: FaceEmbedder()
            )
            await MainActor.run {
                report = outcome
                people = store.all()
                working = false
            }
        }
    }
}

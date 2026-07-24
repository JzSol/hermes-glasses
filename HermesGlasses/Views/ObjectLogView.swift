//
// ObjectLogView.swift
//
// End-of-session review of the Lens object log: saved sessions grouped by
// day, each a list of objects (crop + name + total look-time + count) with
// PDF export. Reads through the view model to LensSessionStore. Pushed as a
// Settings sub-page, so it carries no NavigationStack of its own.
//

import SwiftUI

struct ObjectLogView: View {
    let hermesVM: HermesSessionViewModel

    private var days: [(label: String, sessions: [LensSession])] {
        let all = hermesVM.allLensSessions()  // newest first
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [LensSession]] = [:]
        for session in all {
            let day = calendar.startOfDay(for: session.startedAt)
            if groups[day] == nil {
                groups[day] = []
                order.append(day)
            }
            groups[day]?.append(session)
        }
        return order.map {
            (label: PeopleView.dayLabel($0), sessions: groups[$0] ?? [])
        }
    }

    var body: some View {
        Group {
            if days.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(days, id: \.label) { day in
                        Section(day.label) {
                            ForEach(day.sessions) { session in
                                NavigationLink {
                                    LensSessionDetailView(
                                        hermesVM: hermesVM, session: session
                                    )
                                } label: {
                                    sessionRow(session)
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    hermesVM.deleteLensSession(id: day.sessions[index].id)
                                }
                            }
                        }
                    }
                }
            }
        }
        // Re-read the store after a save/delete.
        .id(hermesVM.lensSessionRevision)
        .navigationTitle("Object Log")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sessionRow(_ session: LensSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.subheadline)
            Text("\(session.entries.count) object\(session.entries.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.headline)
            Text("Open Lens and hold objects under the center reticle. When you close Lens, the session is saved here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LensSessionDetailView: View {
    let hermesVM: HermesSessionViewModel
    let session: LensSession

    @State private var shareURL: URL?
    @State private var showShare = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(Array(session.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 12) {
                        thumbnail(entry)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.label)
                                .font(.subheadline).bold()
                            Text("\(LensPDFRenderer.timeLabel(entry.totalLookTime))  ·  \(entry.lookCount) look\(entry.lookCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Button {
                    exportPDF()
                } label: {
                    Label("Export PDF", systemImage: "square.and.arrow.up")
                }
                Button("Delete", role: .destructive) {
                    hermesVM.deleteLensSession(id: session.id)
                    dismiss()
                }
            }
        }
        .navigationTitle(
            session.startedAt.formatted(date: .abbreviated, time: .shortened)
        )
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
    }

    @ViewBuilder
    private func thumbnail(_ entry: LensSession.Entry) -> some View {
        if let data = hermesVM.lensSessionPhoto(entry), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(HermesTheme.chipFill)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "cube")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func exportPDF() {
        let rows = session.entries.map { entry -> LensPDFRenderer.Row in
            let image = hermesVM.lensSessionPhoto(entry).flatMap(UIImage.init(data:))
            return LensPDFRenderer.Row(
                label: entry.label, totalLookTime: entry.totalLookTime,
                lookCount: entry.lookCount, image: image
            )
        }
        let title = "Object Log — " + session.startedAt.formatted(
            date: .abbreviated, time: .shortened
        )
        let data = LensPDFRenderer.makePDF(title: title, rows: rows)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("object-log-\(session.id.uuidString).pdf")
        try? data.write(to: url, options: .atomic)
        shareURL = url
        showShare = true
    }
}

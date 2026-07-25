//
// ObjectLogView.swift
//
// End-of-session review of the Lens object log: saved sessions grouped by
// day, each a list of objects (crop + name + total look-time + count) with
// PDF export. Reads through the view model to LensSessionStore.
//
// The session detail follows screen 4d: three stat tiles up top, then one
// row per object with an attention bar so look-time is scannable at a
// glance, and export/delete as capsule buttons at the foot.
//

import SwiftUI

struct ObjectLogView: View {
    let hermesVM: HermesSessionViewModel

    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
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
                    .scrollContentBackground(.hidden)
                    .background(HermesTheme.groupedCanvas.ignoresSafeArea())
                }
            }
            // Re-read the store after a save/delete.
            .id(hermesVM.lensSessionRevision)
            .navigationTitle("Object Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(HermesTheme.accent)
    }

    private func sessionRow(_ session: LensSession) -> some View {
        HStack(spacing: 12) {
            HermesIconTile(systemName: "camera.viewfinder", size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 16))
                Text("\(session.entries.count) object\(session.entries.count == 1 ? "" : "s") · \(LensPDFRenderer.timeLabel(totalTime(session)))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func totalTime(_ session: LensSession) -> TimeInterval {
        session.entries.reduce(0) { $0 + $1.totalLookTime }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(HermesTheme.accent.opacity(0.5))
            Text("No sessions yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Open Lens and hold objects under the center reticle. When you close Lens, the session is saved here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.groupedCanvas.ignoresSafeArea())
    }
}

// MARK: - Session detail (4d)

private struct LensSessionDetailView: View {
    let hermesVM: HermesSessionViewModel
    let session: LensSession

    @State private var shareItem: ShareItem?
    @Environment(\.dismiss) private var dismiss

    /// The longest look, used to scale every attention bar.
    private var peak: TimeInterval {
        max(session.entries.map(\.totalLookTime).max() ?? 0, 0.001)
    }

    private var totalLookTime: TimeInterval {
        session.entries.reduce(0) { $0 + $1.totalLookTime }
    }

    private var totalLooks: Int {
        session.entries.reduce(0) { $0 + $1.lookCount }
    }

    var body: some View {
        HermesScrollPage {
            HStack(spacing: 10) {
                HermesStatTile(
                    value: "\(session.entries.count)", caption: "objects"
                )
                HermesStatTile(
                    value: LensPDFRenderer.timeLabel(totalLookTime),
                    caption: "total look-time"
                )
                HermesStatTile(value: "\(totalLooks)", caption: "looks")
            }
            .padding(.horizontal, 16)

            HermesCard {
                ForEach(Array(session.entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { HermesDivider() }
                    objectRow(entry)
                }
            }

            HStack(spacing: 10) {
                HermesPrimaryButton(
                    title: "Export PDF",
                    systemImage: "square.and.arrow.up"
                ) {
                    exportPDF()
                }
                HermesDestructiveButton(title: "Delete") {
                    hermesVM.deleteLensSession(id: session.id)
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle(
            session.startedAt.formatted(date: .abbreviated, time: .shortened)
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func objectRow(_ entry: LensSession.Entry) -> some View {
        HStack(spacing: 12) {
            thumbnail(entry)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.label)
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(LensPDFRenderer.timeLabel(entry.totalLookTime)) · \(entry.lookCount) look\(entry.lookCount == 1 ? "" : "s")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HermesAttentionBar(fraction: entry.totalLookTime / peak)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 66)
    }

    @ViewBuilder
    private func thumbnail(_ entry: LensSession.Entry) -> some View {
        if let data = hermesVM.lensSessionPhoto(entry), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HermesTheme.mediaPlaceholder)
                .frame(width: 52, height: 52)
                .overlay {
                    Text(entry.label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 3)
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
        shareItem = ShareItem(url: url)
    }
}

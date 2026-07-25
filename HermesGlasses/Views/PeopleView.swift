//
// PeopleView.swift
//
// End-of-day review of the people met: photo + spoken note, grouped by
// day. Reads straight through the view model to EncounterStore and
// re-reads whenever `encounterRevision` changes.
//
// Screen 4e: the note leads and the face comes second - what you said
// about someone is what you'll search for - and the on-device badge sits
// at the top, because "does this leave my phone?" is the first question
// anyone asks of this feature.
//

import SwiftUI

struct PeopleView: View {
    let hermesVM: HermesSessionViewModel

    @Environment(\.dismiss) private var dismiss

    private var days: [(label: String, encounters: [Encounter])] {
        let all = hermesVM.allEncounters()  // newest first
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [Encounter]] = [:]
        for encounter in all {
            let day = calendar.startOfDay(for: encounter.timestamp)
            if groups[day] == nil {
                groups[day] = []
                order.append(day)
            }
            groups[day]?.append(encounter)
        }
        return order.map { (label: Self.dayLabel($0), encounters: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    emptyState
                } else {
                    HermesScrollPage {
                        HermesNotice(text: "Stored on this iPhone only")

                        ForEach(Array(days.enumerated()), id: \.element.label) { index, day in
                            HermesSection(
                                header: day.label,
                                footer: index == days.count - 1
                                    ? "Say \"remember this person\" while looking at them."
                                    : nil
                            ) {
                                ForEach(Array(day.encounters.enumerated()), id: \.element.id) { row, encounter in
                                    if row > 0 { HermesDivider() }
                                    NavigationLink {
                                        EncounterDetailView(
                                            hermesVM: hermesVM, encounter: encounter
                                        )
                                    } label: {
                                        EncounterRow(
                                            hermesVM: hermesVM, encounter: encounter
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Delete", role: .destructive) {
                                            hermesVM.deleteEncounter(id: encounter.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Re-read the store after a save/edit/delete.
            .id(hermesVM.encounterRevision)
            .navigationTitle("People")
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 40))
                .foregroundStyle(HermesTheme.accent.opacity(0.5))
            Text("No one yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Say \"remember this person\" while wearing the glasses. Hermes takes a photo and saves the note you speak next.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.groupedCanvas.ignoresSafeArea())
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct EncounterRow: View {
    let hermesVM: HermesSessionViewModel
    let encounter: Encounter

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(encounter.note.isEmpty ? "No note" : "\u{201C}\(encounter.note)\u{201D}")
                    .font(.system(size: 15))
                    .foregroundStyle(encounter.note.isEmpty
                        ? AnyShapeStyle(Color.secondary)
                        : AnyShapeStyle(Color.primary))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: photoCount > 1 ? "waveform" : "mic.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(HermesTheme.accent)
                    Text(metaLine)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var photoCount: Int {
        encounter.photoFilenames.count
    }

    private var metaLine: String {
        let time = encounter.timestamp.formatted(date: .omitted, time: .shortened)
        // A multi-photo entry is a recorded conversation, not a single snap.
        if photoCount > 1 {
            return "conversation · \(photoCount) snaps · \(time)"
        }
        return "spoken note · \(time)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = hermesVM.encounterPhoto(encounter),
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HermesTheme.mediaPlaceholder)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct EncounterDetailView: View {
    let hermesVM: HermesSessionViewModel
    let encounter: Encounter

    @State private var note: String = ""
    @Environment(\.dismiss) private var dismiss

    /// All photos on the entry - one for a classic capture, several for a
    /// recorded conversation.
    private var photos: [UIImage] {
        hermesVM.encounterPhotos(encounter).compactMap(UIImage.init(data:))
    }

    var body: some View {
        Form {
            let photos = self.photos
            if photos.count == 1, let image = photos.first {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .listRowInsets(EdgeInsets())
            } else if photos.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 180, height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Note") {
                TextField("Name, where you met, follow-up…", text: $note, axis: .vertical)
                    .lineLimit(3...10)
            }

            Section {
                LabeledContent(
                    "Met",
                    value: encounter.timestamp.formatted(
                        date: .abbreviated, time: .shortened
                    )
                )
            }

            Section {
                Button("Delete", role: .destructive) {
                    hermesVM.deleteEncounter(id: encounter.id)
                    dismiss()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HermesTheme.groupedCanvas.ignoresSafeArea())
        .navigationTitle("Person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
        .onAppear { note = encounter.note }
        .onDisappear {
            // Swipe-back must not discard an edit (same contract as Settings).
            if note != encounter.note {
                hermesVM.updateEncounterNote(id: encounter.id, note: note)
            }
        }
    }
}

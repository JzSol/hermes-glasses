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

    private var days: [(date: Date, label: String, encounters: [Encounter])] {
        // Read the revision so @Observable tracks it: allEncounters() reads
        // the store directly, so nothing else here tells SwiftUI to re-run.
        // This replaces an .id(revision) on the NavigationStack root, which
        // rebuilt the whole tree - popping an open detail screen and
        // discarding an in-progress name edit every time the badge-assist
        // pass bumped the revision asynchronously.
        _ = hermesVM.encounterRevision
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
        return order.map { (date: $0, label: Self.dayLabel($0), encounters: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    emptyState
                } else {
                    HermesScrollPage {
                        HermesNotice(text: hermesVM.badgeAssistEnabled
                            ? "Stored on this iPhone · badge photos sent to your AI provider"
                            : "Stored on this iPhone only",
                            systemImage: hermesVM.badgeAssistEnabled ? "cloud" : "lock")

                        ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
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

    /// Loaded once in `.onAppear`, never read from `body` - the same defect
    /// `TimelineRowView` and `SightingDetailView` fix below: `body` re-runs
    /// whenever the list recomputes (a badge-assist revision bump, a scroll
    /// pass), and re-decoding the JPEG off disk each time is a real cost
    /// with a screenful of rows.
    @State private var thumbnailImage: UIImage?

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
        .onAppear(perform: loadThumbnail)
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

    private func loadThumbnail() {
        guard thumbnailImage == nil,
              let data = hermesVM.encounterPhoto(encounter)
        else { return }
        thumbnailImage = UIImage(data: data)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailImage {
            Image(uiImage: thumbnailImage)
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

    private var timeline: EncounterTimeline { EncounterTimeline.build(encounter) }

    var body: some View {
        Group {
            switch timeline.kind {
            case .singleNote: singleNote
            case .conversation: conversation
            }
        }
        .navigationTitle(timeline.kind == .conversation ? "Conversation" : "Person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
    }

    // MARK: - Single note (a "remember this person" capture, unchanged)

    private var singleNote: some View {
        Form {
            if let filename = encounter.photoFilenames.first,
               let data = hermesVM.encounterPhotoData(filename: filename),
               let image = UIImage(data: data) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .listRowInsets(EdgeInsets())
            }

            Section("Note") {
                TextField("Name, where you met, follow-up…", text: $note, axis: .vertical)
                    .lineLimit(3...10)
            }

            Section {
                LabeledContent("Met", value: encounter.timestamp.formatted(
                    date: .abbreviated, time: .shortened))
            }

            Section {
                Button("Delete", role: .destructive) {
                    hermesVM.deleteEncounter(id: encounter.id)
                    dismiss()
                }
            }
        }
        .hermesFormStyle()
        .onAppear { note = encounter.note }
        .onDisappear {
            // Swipe-back must not discard an edit (same contract as Settings).
            if note != encounter.note {
                hermesVM.updateEncounterNote(id: encounter.id, note: note)
            }
        }
    }

    // MARK: - Conversation timeline

    private var conversation: some View {
        HermesScrollPage {
            HermesSection(header: header) {
                let rows = timeline.rows
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { HermesDivider() }
                    TimelineRowView(
                        hermesVM: hermesVM,
                        encounterID: encounter.id,
                        row: row,
                        showsTime: showsTime(rows, index)
                    )
                }
            }

            if hermesVM.transcriptionIsRunning {
                HermesNotice(
                    text: "Transcribing the recording - this entry will update itself.",
                    systemImage: "waveform")
            }

            // The way out of an all-"Unnamed" capture. Badge assist is off by
            // default and stays that way (it spends money on every recording),
            // so without a per-encounter trigger a sighting Vision could not
            // read had no route to a name at all.
            if hasUnnamedSightings {
                Button {
                    hermesVM.readBadgesWithAI(for: encounter.id)
                } label: {
                    Label(
                        hermesVM.badgeAssistIsRunning
                            ? "Reading badges…" : "Read badges with AI",
                        systemImage: "sparkles")
                }
                .font(.system(size: 15, weight: .semibold))
                .disabled(hermesVM.badgeAssistIsRunning)
                .padding(.top, 4)

                HermesNotice(
                    text: "Sends the unnamed sightings' photos to \(hermesVM.directProvider.displayName).",
                    systemImage: "cloud")
            }

            Button("Delete", role: .destructive) {
                hermesVM.deleteEncounter(id: encounter.id)
                dismiss()
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.top, 4)
        }
    }

    /// True when at least one sighting has a photo but no name - the only
    /// state in which an AI read has anything to do.
    private var hasUnnamedSightings: Bool {
        encounter.events.contains {
            $0.kind == .sighting && $0.badge?.name == nil
                && !$0.photoFilenames.isEmpty
        }
    }

    private var header: String {
        let start = encounter.timestamp.formatted(date: .omitted, time: .shortened)
        let people = timeline.rows.filter {
            if case .sighting = $0.content { return true }
            return false
        }.count
        return people == 0
            ? start
            : "\(start) · \(people) \(people == 1 ? "person" : "people")"
    }

    /// A timestamp is printed only when the minute changes, so a fast
    /// exchange is not a column of identical clocks.
    private func showsTime(_ rows: [EncounterTimeline.Row], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let calendar = Calendar.current
        return !calendar.isDate(
            rows[index].timestamp, equalTo: rows[index - 1].timestamp,
            toGranularity: .minute
        )
    }
}

/// One row: someone seen, or something said.
private struct TimelineRowView: View {
    let hermesVM: HermesSessionViewModel
    let encounterID: UUID
    let row: EncounterTimeline.Row
    let showsTime: Bool

    /// Loaded once in `.onAppear`, never read from `body` - the same defect
    /// `SightingDetailView` fixed: `body` re-runs whenever the list
    /// recomputes (every badge-assist revision bump, every scroll pass), and
    /// re-reading the JPEG off disk each time is a real cost.
    @State private var thumbnailImage: UIImage?

    var body: some View {
        content.onAppear(perform: loadThumbnail)
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case .sighting(let filenames, let badge):
            NavigationLink {
                SightingDetailView(
                    hermesVM: hermesVM, encounterID: encounterID,
                    eventIDs: row.eventIDs, filenames: filenames, badge: badge
                )
            } label: {
                sighting(filenames: filenames, badge: badge)
            }
            .buttonStyle(.plain)
            .disabled(row.eventIDs.isEmpty)

        case .speech(let text):
            speech(text)
        }
    }

    private func sighting(filenames: [String], badge: Badge?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(badge?.name ?? "Unnamed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(badge?.name == nil
                        ? AnyShapeStyle(Color.secondary)
                        : AnyShapeStyle(Color.primary))
                if let subtitle = badge?.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(timeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if filenames.count > 1 {
                        Text("\(filenames.count) frames")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if badge?.source == .assisted {
                        Text("read by AI")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HermesTheme.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func speech(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(showsTime ? timeLabel : "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var timeLabel: String {
        row.timestamp.formatted(date: .omitted, time: .shortened)
    }

    private func loadThumbnail() {
        guard thumbnailImage == nil,
              case .sighting(let filenames, _) = row.content,
              let filename = filenames.first,
              let data = hermesVM.encounterPhotoData(filename: filename)
        else { return }
        thumbnailImage = UIImage(data: data)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = thumbnailImage {
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

/// Every frame of one person, what OCR actually saw, and a correctable name.
private struct SightingDetailView: View {
    let hermesVM: HermesSessionViewModel
    let encounterID: UUID
    let eventIDs: [UUID]
    let filenames: [String]
    let badge: Badge?

    @State private var name: String = ""
    /// Loaded once in `.onAppear`, not read from `body` - `body` re-runs on
    /// every keystroke in the name field, and re-reading every JPEG in the
    /// row from disk per keystroke was a real, measured cost at 12 photos.
    @State private var images: [UIImage] = []
    /// Same reasoning as `images`: `encounterPhotoData` bottoms out in a
    /// synchronous disk-queue hop plus a JPEG decode, so it must not run on
    /// every keystroke either.
    @State private var portrait: UIImage?

    var body: some View {
        Form {
            if !images.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
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

            Section {
                TextField("Name", text: $name)
                    .disabled(eventIDs.isEmpty)
            } header: {
                Text("Name")
            } footer: {
                Text(eventIDs.isEmpty
                     ? "This entry predates name tags, so its name can't be edited."
                     : "Correct it if the badge was misread.")
            }

            if let badge, badge.kind != nil || badge.portraitFilename != nil {
                Section {
                    if let kind = badge.kind {
                        Text(kind.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let portrait {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Photo on the badge")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Image(uiImage: portrait)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            if let badge, !badge.rawLines.isEmpty {
                Section {
                    ForEach(Array(badge.rawLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What was read")
                } footer: {
                    Text(badge.source == .assisted
                         ? "Read by your AI provider."
                         : "Read on this iPhone.")
                }
            }
        }
        .hermesFormStyle()
        .navigationTitle(badge?.name ?? "Unnamed")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = badge?.name ?? ""
            images = filenames.compactMap { hermesVM.encounterPhotoData(filename: $0) }
                .compactMap(UIImage.init(data:))
            portrait = badge?.portraitFilename
                .flatMap { hermesVM.encounterPhotoData(filename: $0) }
                .flatMap(UIImage.init(data:))
        }
        .onDisappear {
            // Swipe-back must not discard an edit (same contract as Settings).
            guard !eventIDs.isEmpty else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (badge?.name ?? "") else { return }
            hermesVM.renameEncounterSighting(
                encounterID: encounterID, eventIDs: eventIDs,
                name: trimmed.isEmpty ? nil : trimmed
            )
        }
    }
}

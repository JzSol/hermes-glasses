//
// AppDrawerView.swift
//
// Everything Hermes can do, in one place. The quick-action row under the
// conversation shows the first few; pulling up (or tapping the handle)
// opens this.
//
// The row is for reach, not for completeness - and neither is the real
// launcher. On glasses the launcher is your voice, which is why each app
// here shows the phrase that starts it. This screen is for finding out
// what exists and for the apps that have no phrase at all.
//

import SwiftUI

struct AppDrawerView: View {
    let apps: [HermesApp]
    /// Nil while nothing is unavailable; otherwise why, per app id.
    var unavailable: (HermesApp) -> String?
    let onOpen: (HermesApp) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HermesScrollPage {
                HermesSection(
                    footer: "On the glasses, your voice is the launcher - say the phrase and the app opens itself."
                ) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { HermesDivider() }
                        row(app)
                    }
                }
            }
            .navigationTitle("Apps")
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

    private func row(_ app: HermesApp) -> some View {
        let blockedReason = unavailable(app)
        return Button {
            guard blockedReason == nil else { return }
            dismiss()
            onOpen(app)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                HermesIconTile(systemName: app.systemImage, size: 36)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(app.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        if app.isVoiceLaunchable {
                            HermesBadge(text: "Voice", prominent: true)
                        }
                    }

                    Text(blockedReason ?? app.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(blockedReason == nil
                            ? AnyShapeStyle(Color.secondary)
                            : AnyShapeStyle(HermesTheme.accentOnCard))
                        .fixedSize(horizontal: false, vertical: true)

                    // What it touches, said up front rather than discovered
                    // when a permission prompt appears.
                    HStack(spacing: 5) {
                        ForEach(app.capabilities) { capability in
                            HermesChip(text: capability.label, size: 10)
                        }
                    }
                }

                Spacer(minLength: 4)
                HermesChevron()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .opacity(blockedReason == nil ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(blockedReason != nil)
    }
}

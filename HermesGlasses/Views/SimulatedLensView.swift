//
// SimulatedLensView.swift
//
// The lens, on the phone's screen. Renders the same `LensContent` the
// glasses render (design 5b), inside a framed box labelled with the real
// lens resolution - so what you see here is what a wearer would see.
//
// Read-only: it takes a value and draws it. Everything about what SHOULD be
// on the lens is decided by HermesDisplayManager, exactly as for glasses.
//

import SwiftUI

struct SimulatedLensView: View {
    let content: LensContent
    /// Drawn on the frame's tag. Ray-Ban Display's usable HUD area.
    var resolutionLabel: String = "640×200"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HermesScreenTitle(
                text: "HERMES", size: 13, tint: HermesTheme.accentLight.opacity(0.9)
            )

            if let imageURL = content.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        HermesTheme.cream.opacity(0.08)
                    }
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let label = content.label {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(HermesTheme.accentLight.opacity(0.8))
            }

            if !content.body.isEmpty {
                Text(content.body)
                    .font(.system(size: 19, weight: .semibold))
                    .kerning(-0.2)
                    .foregroundStyle(HermesTheme.cream)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = content.statusLine {
                HStack(spacing: 8) {
                    if content.isLive {
                        Circle()
                            .fill(HermesTheme.online)
                            .frame(width: 7, height: 7)
                    }
                    Text(status)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(HermesTheme.cream.opacity(0.55))
                        .lineLimit(1)
                }
            }

            if case .reply(_, _, let choices) = content, !choices.isEmpty {
                HStack(spacing: 6) {
                    ForEach(choices.prefix(3)) { choice in
                        Text(choice.shortLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(HermesTheme.accent, in: Capsule())
                    }
                    if choices.count > 3 {
                        Text("+\(choices.count - 3)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HermesTheme.cream.opacity(0.6))
                    }
                }
            }

            if case .navigation(_, _, _, _, let mode) = content {
                HStack(spacing: 6) {
                    modeChip("Walk", active: mode == .walking)
                    modeChip("Drive", active: mode == .driving)
                }
            }

            if content.isBlank {
                Text("Lens is idle")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(HermesTheme.cream.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            HermesTheme.lensChrome.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .background(.ultraThinMaterial.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(HermesTheme.accent.opacity(0.55), lineWidth: 1.5)
        }
        .overlay(alignment: .topLeading) {
            // The tag is the honesty label: this is a stand-in, at the real
            // lens's aspect, not a Hermes screen invented for the phone.
            Text("SIMULATED LENS · \(resolutionLabel)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .kerning(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(HermesTheme.accent,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .offset(x: 12, y: -9)
        }
        .animation(.easeOut(duration: 0.2), value: content)
    }

    /// Mirrors the buttons the wearer sees on the real lens.
    private func modeChip(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? .white : HermesTheme.cream.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                active ? HermesTheme.accent : HermesTheme.cream.opacity(0.12),
                in: Capsule()
            )
    }
}

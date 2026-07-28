//
// PhoneModeSessionView.swift
//
// Design 5b: no glasses on you, so the phone is the eye. The rear camera
// fills the frame, the simulated lens sits over it showing exactly what a
// wearer would see, and the usual waveform bar runs underneath.
//
// This replaces the chat body only while a phone-mode session is running.
// The Transcript button flips back to the conversation, so nothing the
// assistant said is ever more than one tap away.
//

import SwiftUI

struct PhoneModeSessionView: View {
    let hermesVM: HermesSessionViewModel
    /// Flip to the chat transcript.
    let onShowTranscript: () -> Void
    /// Open Settings → Devices.
    let onOpenDevices: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            stage
            tiles
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensChrome.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HermesScreenTitle(text: "PHONE MODE")
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(HermesTheme.cream.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            HermesChromePill(title: "Transcript", action: onShowTranscript)
            HermesChromePill(title: "Devices", action: onOpenDevices)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        if hermesVM.phoneCameraError != nil { return "Camera unavailable" }
        return hermesVM.glassesAvailable
            ? "Glasses on · phone forced"
            : "No glasses · simulating lens"
    }

    // MARK: - Camera stage + simulated lens

    private var stage: some View {
        ZStack(alignment: .top) {
            feed

            SimulatedLensView(content: hermesVM.lensContent)
                .padding(.horizontal, 26)
                .padding(.top, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensStage)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                stageChip("iPhone rear cam")
                if hermesVM.phoneCamera.isStreaming {
                    stageChip("live")
                }
            }
            .padding(12)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var feed: some View {
        if let image = hermesVM.phoneFeedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if let error = hermesVM.phoneCameraError {
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(HermesTheme.cream.opacity(0.4))
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(HermesTheme.cream.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Button {
                    openSettings()
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HermesTheme.accentLight)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(HermesTheme.accentLight)
                Text("Starting the iPhone camera…")
                    .font(.system(size: 13))
                    .foregroundStyle(HermesTheme.cream.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stageChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(HermesTheme.cream.opacity(0.7))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                HermesTheme.lensChrome.opacity(0.7),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }

    // MARK: - Status tiles

    private var tiles: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                tile(caption: "Lens preset", value: "Ray-Ban Display")
                tile(caption: "Camera", value: hermesVM.phoneCamera.lensDescription)
            }

            HStack(spacing: 12) {
                Text("Speak replies aloud")
                    .font(.system(size: 14))
                    .foregroundStyle(HermesTheme.cream.opacity(0.8))
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { hermesVM.useDeviceTTS },
                    set: { hermesVM.useDeviceTTS = $0 }
                ))
                .labelsHidden()
                .tint(HermesTheme.accent)
                .accessibilityLabel("Speak replies aloud")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                HermesTheme.cream.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func tile(caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(HermesTheme.cream.opacity(0.5))
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HermesTheme.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            HermesTheme.cream.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

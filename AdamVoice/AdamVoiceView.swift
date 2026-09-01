//
// AdamVoiceView.swift
//
// Small setup and live-status surface for the voice-only Adam target.
//

import SwiftUI

struct AdamVoiceView: View {
    let session: AdamVoiceSession

    @State private var endpointDraft: String
    @State private var tokenDraft = ""
    @State private var vocabularyDraft: String

    init(session: AdamVoiceSession) {
        self.session = session
        _endpointDraft = State(initialValue: session.endpoint)
        _vocabularyDraft = State(initialValue: session.vocabulary)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard
                    conversation
                    setup
                    Text(Self.versionLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("Adam")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(session.isRunning ? "Stop" : "Start") {
                        if session.isRunning {
                            session.stop()
                        } else {
                            session.start()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .task {
            endpointDraft = session.endpoint
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                Text(session.status.label)
                    .font(.headline)
                Spacer()
                if session.status == .connecting
                    || session.status == .reconnecting
                    || session.status == .transcribing
                    || session.status == .thinking
                    || session.status == .preparingVoice
                    || session.status == .processing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if session.canCancelTurn {
                Button("Cancel", role: .cancel) {
                    session.cancelTurn()
                }
                .buttonStyle(.bordered)
            } else if session.canRetryTurn {
                Button("Retry") {
                    session.retryTurn()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Say “Adam”, then ask a question.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            routeRow(title: "Input", value: session.micRoute, systemImage: "mic.fill")
            routeRow(title: "Output", value: session.outputRoute, systemImage: "speaker.wave.2.fill")

            if session.isRunning {
                HStack(spacing: 8) {
                    Text("Mic level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(min(max(session.micLevel, 0), 1)))
                        .tint(.accentColor)
                }
            }

            if let warning = session.micWarning, !warning.isEmpty {
                Label(warning, systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !session.isOnDeviceSpeechSupported {
                Label(
                    "On-device speech recognition is unavailable for this device or language.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let message = session.errorMessage, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation")
                    .font(.title3.weight(.semibold))
                Spacer()
                if session.isRunning {
                    Button("New") { session.resetConversation() }
                        .font(.subheadline.weight(.medium))
                }
            }

            if !session.liveTranscript.isEmpty {
                transcriptBubble(
                    label: "Heard",
                    text: session.liveTranscript,
                    tint: Color.secondary.opacity(0.12)
                )
            }
            if !session.lastCommand.isEmpty {
                transcriptBubble(
                    label: "Heard",
                    text: session.lastCommand,
                    tint: Color.accentColor.opacity(0.12)
                )
            }
            if !session.lastResponse.isEmpty {
                transcriptBubble(
                    label: "Adam",
                    text: session.lastResponse,
                    tint: Color.green.opacity(0.12)
                )
            }
            if session.liveTranscript.isEmpty
                && session.lastCommand.isEmpty
                && session.lastResponse.isEmpty {
                Text("Adam stays quiet until a wake phrase is heard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Hermes bridge endpoint")
                    .font(.subheadline.weight(.medium))
                TextField(
                    "wss://your-machine.ts.net:8443/voice",
                    text: $endpointDraft
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                Button("Save endpoint") {
                    _ = session.saveEndpoint(endpointDraft)
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bridge token")
                    .font(.subheadline.weight(.medium))
                SecureField("Bearer token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save token") {
                        if session.saveToken(tokenDraft) {
                            tokenDraft = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    if session.tokenConfigured {
                        Text("Saved in Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear", role: .destructive) {
                            _ = session.clearToken()
                        }
                        .font(.caption)
                    }
                }
            }

            Picker(
                "Language",
                selection: Binding(
                    get: { session.locale },
                    set: { _ = session.setLocale($0) }
                )
            ) {
                ForEach(VoiceLocale.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.menu)

            if !session.selectedVoiceDescription.isEmpty {
                Label(session.selectedVoiceDescription, systemImage: "person.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notice = session.voiceNotice, !notice.isEmpty {
                Label(notice, systemImage: "speaker.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(
                "Listening sounds",
                isOn: Binding(
                    get: { session.listeningSoundsEnabled },
                    set: { session.setListeningSounds($0) }
                )
            )

            Text("A short flute cue opens listening. A quiet tick marks speech, a droplet marks its end, and a soft pulse marks thinking.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Speech vocabulary")
                    .font(.subheadline.weight(.medium))
                TextField("Names and terms, separated by commas", text: $vocabularyDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Save vocabulary") {
                    session.saveVocabulary(vocabularyDraft)
                }
                .buttonStyle(.bordered)
            }

            Text("The bridge endpoint is stored in app settings. The token is stored only in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func routeRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func transcriptBubble(label: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusColor: Color {
        switch session.status {
        case .idle:
            return .secondary
        case .connecting, .reconnecting, .transcribing, .thinking,
             .preparingVoice, .processing:
            return .orange
        case .armed, .wakeAcknowledged, .hearingSpeech, .listening, .awaitingCommand:
            return .green
        case .speaking:
            return .blue
        case .failed:
            return .red
        }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Adam \(version) (\(build))"
    }
}

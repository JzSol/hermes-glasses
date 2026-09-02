//
// AdamVoiceView.swift
//
// Hermes' chat-first interface adapted to the camera-free Adam session.
// All service ownership remains in AdamVoiceSession; this file is values,
// bindings, and user actions only.
//

import SwiftUI

struct AdamVoiceView: View {
    let session: AdamVoiceSession

    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if showsWelcome {
                welcome
            } else {
                AssistantConversationSurface(
                    turns: session.conversationHistory,
                    pendingUserText: session.pendingConversationUserText,
                    liveTranscript: session.liveTranscript,
                    liveTranscriptLabel: transcriptLabel,
                    streamingResponse: session.streamingConversationResponse,
                    activity: conversationActivity,
                    onInterruptSpeech: session.status == .speaking
                        ? { session.cancelTurn() } : nil
                )
            }

            statusNotices
            capabilityStrip

            sessionBar
        }
        .sensoryFeedback(.start, trigger: session.sensoryFeedbackEvent) { _, newEvent in
            session.hapticsEnabled
                && newEvent == .wakeCueStarted
                && session.isWakeCueCaptureGuardActive
        }
        .sensoryFeedback(.stop, trigger: session.sensoryFeedbackEvent) { _, newEvent in
            session.hapticsEnabled
                && newEvent == .transcriptionStarted
                && !session.isWakeCueCaptureGuardActive
        }
        .background(HermesTheme.canvas)
        .tint(HermesTheme.accent)
        .sheet(isPresented: $showSettings) {
            AdamSettingsView(session: session)
        }
    }

    private var sessionBar: AssistantSessionBar {
        AssistantSessionBar(
            isRunning: session.isRunning,
            micLevel: session.micLevel,
            statusLabel: session.status.label,
            isError: session.status == .failed,
            startTitle: "Start listening",
            canStart: session.tokenConfigured,
            startNote: session.tokenConfigured
                ? nil : "Add the bridge token in Settings before starting.",
            contextActionTitle: contextActionTitle,
            contextActionIsDestructive: session.canCancelTurn,
            presentationPhase: session.presentationFeedbackPhase,
            onStart: { session.start() },
            onContextAction: contextAction,
            onEnd: { session.stop() }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            HermesLockup(height: 16)

            Spacer(minLength: 4)

            Button {
                session.resetConversation()
            } label: {
                headerIcon("plus")
            }
            .buttonStyle(.plain)
            .disabled(!session.isRunning)
            .opacity(session.isRunning ? 1 : 0.45)
            .accessibilityLabel("New conversation")

            HermesStatusPill(
                text: session.bridgeConnected ? "Bridge" : "Offline",
                dot: session.bridgeConnected ? HermesTheme.online : .gray,
                tinted: session.bridgeConnected
            )

            Button {
                showSettings = true
            } label: {
                headerIcon("gearshape")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Color.secondary.opacity(0.12), in: Circle())
    }

    private var showsWelcome: Bool {
        session.conversationHistory.isEmpty
            && session.pendingConversationUserText.isEmpty
            && session.liveTranscript.isEmpty
            && session.streamingConversationResponse.isEmpty
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()

            HermesLockup(height: 26, showsSuffix: true)

            VStack(spacing: 8) {
                Text(session.isRunning ? "Ready to talk to Adam" : "Start Adam when you're ready")
                    .font(.title.weight(.bold))
                    .kerning(-0.5)
                    .multilineTextAlignment(.center)

                Text("Say “Adam”, wait for the flute cue, then ask your question. Replies play through your Ray-Ban speakers.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var statusNotices: some View {
        if let warning = session.micWarning, !warning.isEmpty {
            HermesNotice(text: warning, systemImage: "mic.slash")
                .padding(.bottom, 6)
        }

        if let message = session.errorMessage, !message.isEmpty,
           session.tokenConfigured || session.isRunning
            || !message.localizedCaseInsensitiveContains("bridge token") {
            HermesNotice(text: message, systemImage: "exclamationmark.triangle")
                .padding(.bottom, 6)
        }
    }

    private var capabilityStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HermesChip(text: "Ray-Ban audio")
                HermesChip(text: "Conversation history")
                HermesChip(text: "Camera unavailable", available: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Adam capabilities")
    }

    private var transcriptLabel: String {
        switch session.status {
        case .transcribing:
            return "Transcribing with the Hermes bridge…"
        case .transcriptReady:
            return "Transcript complete — preparing Adam’s reply…"
        case .paused:
            return "Paused — continue speaking or say “That’s it” to send"
        case .wakeAcknowledged, .hearingSpeech, .awaitingCommand:
            return "Listening through the Ray-Ban microphone…"
        default:
            return "Recognizing the wake phrase on this iPhone…"
        }
    }

    private var conversationActivity: AssistantConversationActivity {
        switch session.status {
        case .transcribing, .transcriptReady, .thinking, .preparingVoice, .processing:
            return .processing(session.status.label)
        case .speaking:
            return .speaking("Adam is speaking - tap to stop")
        default:
            return .idle
        }
    }

    private var contextActionTitle: String? {
        if session.canCancelTurn { return "Cancel" }
        if session.canRetryTurn { return "Retry" }
        return nil
    }

    private var contextAction: (() -> Void)? {
        if session.canCancelTurn { return { session.cancelTurn() } }
        if session.canRetryTurn { return { session.retryTurn() } }
        return nil
    }
}

private struct AdamSettingsView: View {
    let session: AdamVoiceSession

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw =
        AppearanceMode.system.rawValue
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
            HermesScrollPage {
                HermesDeviceCard(
                    title: "Ray-Ban audio",
                    status: session.isRunning ? session.micRoute : "Ready when Adam starts",
                    dot: session.isRunning ? HermesTheme.online : .gray,
                    chips: [
                        (label: "Audio", available: true),
                        (label: "History", available: true),
                        (label: "No camera", available: false),
                    ]
                ) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HermesTheme.accentLight)
                }

                bridgeSection
                voiceSection
                appearanceSection
                capabilitiesSection

                VStack(spacing: 4) {
                    HermesLockup(height: 13, showsSuffix: true)
                    Text(Self.versionLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitDrafts()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onDisappear(perform: commitDrafts)
        }
        .tint(HermesTheme.accent)
    }

    private var bridgeSection: some View {
        HermesSection(
            header: "Assistant bridge",
            footer: "The endpoint stays in app settings. The bearer token stays only in Keychain."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Hermes bridge endpoint", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                TextField("wss://your-machine.ts.net:8443/voice", text: $endpointDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                Button("Save endpoint") {
                    _ = session.saveEndpoint(endpointDraft)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)

            HermesDivider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Bridge token", systemImage: "key")
                    .font(.subheadline.weight(.semibold))
                SecureField("Bearer token", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save token") {
                        if session.saveToken(tokenDraft) {
                            tokenDraft = ""
                            if !session.isRunning { session.start() }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if session.tokenConfigured {
                        Label("Saved", systemImage: "checkmark.circle.fill")
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
            .padding(16)
        }
    }

    private var voiceSection: some View {
        HermesSection(
            header: "Voice & microphone",
            footer: "The wake recognizer runs on this iPhone. Command audio is transcribed by the configured Hermes bridge."
        ) {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HermesDivider()

            Toggle(
                "Listening sounds",
                isOn: Binding(
                    get: { session.listeningSoundsEnabled },
                    set: { session.setListeningSounds($0) }
                )
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HermesDivider()

            Toggle(
                "Haptic feedback",
                isOn: Binding(
                    get: { session.hapticsEnabled },
                    set: { session.setHaptics($0) }
                )
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HermesDivider()

            VStack(alignment: .leading, spacing: 10) {
                Label("Speech vocabulary", systemImage: "textformat.abc")
                    .font(.subheadline.weight(.semibold))
                TextField(
                    "Names and terms, separated by commas",
                    text: $vocabularyDraft
                )
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                Button("Save vocabulary") {
                    session.saveVocabulary(vocabularyDraft)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)

            if !session.selectedVoiceDescription.isEmpty {
                HermesDivider()
                HermesRow(
                    "Reply voice",
                    icon: "person.wave.2",
                    value: session.selectedVoiceDescription,
                    showsChevron: false
                )
            }
        }
    }

    private var appearanceSection: some View {
        HermesSection(header: "Appearance") {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var capabilitiesSection: some View {
        HermesSection(
            header: "Capabilities",
            footer: "Adam intentionally uses the Ray-Bans as Bluetooth audio only. Visual bridge requests return an explicit camera-unavailable error."
        ) {
            HermesRow(
                "Conversation & transcription",
                icon: "text.bubble",
                value: "Available",
                showsChevron: false
            )
            HermesDivider()
            HermesRow(
                "Ray-Ban microphone & speakers",
                icon: "eyeglasses",
                value: "Available",
                showsChevron: false
            )
            HermesDivider()
            HermesRow(
                "Photos & visual questions",
                icon: "camera",
                mutedIcon: true,
                value: "Unavailable",
                showsChevron: false
            )
            HermesDivider()
            HermesRow(
                "Current output",
                icon: "speaker.wave.2",
                value: session.outputRoute,
                showsChevron: false
            )
        }
    }

    private func commitDrafts() {
        if endpointDraft != session.endpoint {
            _ = session.saveEndpoint(endpointDraft)
        }
        if vocabularyDraft != session.vocabulary {
            session.saveVocabulary(vocabularyDraft)
        }
    }

    private static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Adam \(version) (\(build)) · camera-free Ray-Ban audio"
    }
}

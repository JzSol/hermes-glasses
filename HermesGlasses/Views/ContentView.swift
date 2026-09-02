//
// ContentView.swift
//
// Main view for Hermes Glasses. Chat-first session screen per screen 4a
// of the "Hermes Glasses UI" design: brand lockup + status pills in the
// header, terracotta/white bubbles on a cream canvas, a quick-action row
// to the four feature screens, and a waveform bottom bar.
//
// The subsystem test buttons used to float over this screen; per turn 5
// of the design they now live in Settings -> Developer, so nothing
// covers the conversation.
//

import SwiftUI

struct ContentView: View {
    let wearablesVM: WearablesViewModel
    let hermesVM: HermesSessionViewModel

    @State private var showSettings: Bool = false
    @State private var showPeople: Bool = false
    @State private var showLens: Bool = false
    @State private var showObjectLog: Bool = false
    @State private var showMap: Bool = false
    /// In phone mode the 5b camera view is the session screen; this flips to
    /// the chat transcript so the conversation is never unreachable.
    @State private var showTranscript: Bool = false
    /// Set when Settings should open straight onto a sub-page.
    @State private var settingsRoute: SettingsRoute?
    @State private var showAppDrawer: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if showsPhoneModeStage {
                PhoneModeSessionView(
                    hermesVM: hermesVM,
                    onShowTranscript: { showTranscript = true },
                    onOpenDevices: { showSettings = true }
                )
            } else {
                header
                conversationArea
                quickActions
            }
            bottomBar
        }
        .background(showsPhoneModeStage
            ? HermesTheme.lensChrome : HermesTheme.canvas)
        .tint(HermesTheme.accent)
        .sheet(isPresented: $showSettings, onDismiss: { settingsRoute = nil }) {
            SettingsView(
                hermesVM: hermesVM, wearablesVM: wearablesVM,
                initialRoute: settingsRoute
            )
        }
        // Pairing errors are actionable: "already registered" means the fix
        // is re-pairing, which lives in Devices.
        .alert("Glasses", isPresented: Binding(
            get: { wearablesVM.showError },
            set: { if !$0 { wearablesVM.dismissError() } }
        )) {
            Button("Open Devices") {
                wearablesVM.dismissError()
                openDevices()
            }
            Button("OK", role: .cancel) { wearablesVM.dismissError() }
        } message: {
            Text(wearablesVM.errorMessage)
        }
        .sheet(isPresented: $showPeople) {
            PeopleView(hermesVM: hermesVM)
        }
        .sheet(isPresented: $showObjectLog) {
            ObjectLogView(hermesVM: hermesVM)
        }
        .sheet(isPresented: $showMap) {
            NavigationMapView(hermesVM: hermesVM)
        }
        .sheet(isPresented: $showAppDrawer) {
            AppDrawerView(
                apps: HermesAppRegistry.all,
                unavailable: unavailableReason,
                onOpen: open
            )
            .presentationDetents([.medium, .large])
        }
        // fullScreenCover, not sheet - an accidental drag-dismiss would
        // tear down the live stream mid-use; Done is the exit.
        .fullScreenCover(isPresented: $showLens) {
            LensView(hermesVM: hermesVM)
        }
        .task {
            hermesVM.logVisionDiagnostics("app-launch")
            await hermesVM.refreshGlassesCameraStatus()
            await hermesVM.checkBridge()
        }
        // Pairing is the moment to ask for the glasses camera - discovering
        // it via a failed feature is how it went wrong before.
        .onChange(of: wearablesVM.registrationState) { _, state in
            guard state == .registered else { return }
            Task { await hermesVM.ensureGlassesCameraAfterPairing() }
        }
        .onChange(of: hermesVM.phoneModeActive) { _, active in
            if !active { showTranscript = false }
        }
    }

    /// What's wrong with the glasses right now, if anything. Surfaced next
    /// to the toggle rather than waiting for a feature to fail.
    private var glassesWarning: String? {
        guard hermesVM.phoneModePreference != .always else { return nil }
        if !hermesVM.glassesAvailable { return "Glasses aren't reachable" }
        // The Meta AI camera grant is a Ray-Ban thing; AiSee needs none.
        if hermesVM.glassesVendor == .meta, hermesVM.cameraPermissionGranted == false {
            return "Glasses camera isn't allowed - tap to fix"
        }
        return nil
    }

    /// Where the glasses actually stand, so the empty state can stop
    /// offering "Connect Glasses" to glasses that are already paired.
    enum GlassesSetupState {
        case ready                 // reachable, will be used
        case phoneChosen           // user picked the phone; glasses irrelevant
        case notPaired             // never registered - pairing is the fix
        case pairedButUnreachable  // registered, but no eligible device
    }

    private var glassesSetupState: GlassesSetupState {
        if hermesVM.phoneModePreference == .always { return .phoneChosen }
        if hermesVM.glassesAvailable { return .ready }
        return wearablesVM.registrationState == .registered
            ? .pairedButUnreachable : .notPaired
    }

    private var emptyStateTitle: String {
        switch glassesSetupState {
        case .ready: return "Ready to talk to \(assistantName)"
        case .phoneChosen: return "Ready when you are"
        case .notPaired: return "Connect your glasses"
        case .pairedButUnreachable: return "Your glasses aren't reachable"
        }
    }

    private var emptyStateBody: String {
        switch glassesSetupState {
        case .ready, .notPaired:
            return "\(assistantName) talks to you through your Meta Ray-Ban glasses - mic, speaker, and camera."
        case .phoneChosen:
            return "This iPhone is the eye: its camera sees for you and the lens is simulated on screen."
        case .pairedButUnreachable:
            return "They're paired but out of reach right now. Start anyway and this iPhone will be the eye."
        }
    }

    /// Open Settings with Devices already pushed.
    private func openDevices() {
        settingsRoute = .devices
        showSettings = true
    }

    /// The 5b stage owns the screen only while a phone-mode session runs and
    /// the user has not asked for the transcript.
    private var showsPhoneModeStage: Bool {
        hermesVM.phoneModeActive && !showTranscript
    }

    // MARK: - Header (brand lockup + status pills)

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HermesLockup(height: 16)

                Spacer(minLength: 4)

                // New conversation
                iconCircle("plus", label: "New conversation") {
                    hermesVM.startNewConversation()
                }
                .disabled(hermesVM.connectionState == .disconnected)
                .opacity(hermesVM.connectionState == .disconnected ? 0.4 : 1)

                iconCircle("gearshape", label: "Settings") {
                    showSettings = true
                }
            }

            HStack(spacing: 8) {
                HermesEyeToggle(
                    usesGlasses: Binding(
                        get: { hermesVM.phoneModePreference != .always },
                        set: { hermesVM.phoneModePreference = $0 ? .auto : .always }
                    ),
                    glassesWarning: glassesWarning != nil
                )
                .fixedSize()
                .disabled(hermesVM.connectionState != .disconnected)
                .opacity(hermesVM.connectionState == .disconnected ? 1 : 0.5)

                statusPills
            }

            if let glassesWarning {
                Button {
                    if hermesVM.cameraPermissionGranted == false,
                       hermesVM.glassesAvailable {
                        Task { await hermesVM.requestGlassesCameraAccess() }
                    } else {
                        openDevices()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(glassesWarning)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(HermesTheme.accentDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        HermesTheme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Backend and feature state, one pill each. Scrolls horizontally:
    /// the growing Recording label doesn't fit a phone width, and wrapped
    /// pill text is worse.
    private var statusPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Bridge reachability (or provider key status in direct mode)
                if hermesVM.backend == .direct {
                    HermesStatusPill(
                        text: hermesVM.directProvider.displayName,
                        dot: directKeyReady ? HermesTheme.online : .red,
                        tinted: directKeyReady
                    )
                } else {
                    Button {
                        Task { await hermesVM.checkBridge() }
                    } label: {
                        HermesStatusPill(
                            text: "Bridge",
                            dot: bridgeDotColor,
                            tinted: hermesVM.bridgeStatus == .reachable
                        )
                    }
                    .buttonStyle(.plain)
                }

                // AiSee has no lens: a HUD chip there reports a setting that
                // cannot do anything, next to glasses that have no display.
                if hermesVM.glassesSupportsDisplay {
                    HermesStatusPill(
                        text: hermesVM.displayHUDEnabled ? "HUD on" : "HUD off",
                        tinted: hermesVM.displayHUDEnabled
                    )
                }

                // Live capture indicator. The entry point is the Record quick
                // action below - this only earns its place while a capture is
                // running, when the snap count is worth seeing.
                // This pill only ever renders while a capture is running -
                // `conversationCaptureActive` gates the `if` above, so the
                // three ternaries this used to carry were always the same
                // branch.
                if hermesVM.socialNotesEnabled,
                   hermesVM.conversationCaptureActive {
                    Button {
                        hermesVM.toggleConversationCapture()
                    } label: {
                        HermesStatusPill(
                            text: recordingPillLabel,
                            dot: .red,
                            icon: hermesVM.conversationCaptureSnapCount > 0
                                ? "camera.fill" : nil,
                            tinted: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private var recordingPillLabel: String {
        let snaps = hermesVM.conversationCaptureSnapCount
        return snaps == 0 ? "Recording…" : "Recording… \(snaps)"
    }

    private func iconCircle(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var directKeyReady: Bool {
        !hermesVM.directProvider.requiresKey || hermesVM.hasDirectKey
    }

    private var bridgeDotColor: Color {
        switch hermesVM.bridgeStatus {
        case .reachable: return HermesTheme.online
        case .unreachable: return .red
        case .unknown, .checking: return .gray
        }
    }

    // MARK: - Conversation Area

    @ViewBuilder
    private var conversationArea: some View {
        if hermesVM.conversationHistory.isEmpty
            && hermesVM.connectionState == .disconnected {
            emptyState
        } else {
            AssistantConversationSurface(
                turns: hermesVM.conversationHistory,
                defaultPhotoSource: GlassesVendor.meta.cameraLabel,
                pendingUserText: pendingUserText,
                liveTranscript: hermesVM.liveTranscript,
                liveTranscriptLabel: "Transcribing on device…",
                replyChoices: hermesVM.replyChoices.map {
                    AssistantReplyChoice(id: $0.id, label: $0.label)
                },
                activity: conversationActivity,
                onSendNow: hermesVM.liveTranscript.isEmpty
                    ? nil : { hermesVM.sendNow() },
                onChooseReply: { selected in
                    guard let choice = hermesVM.replyChoices.first(
                        where: { $0.id == selected.id }
                    ) else { return }
                    hermesVM.chooseReplyOption(choice)
                },
                onInterruptSpeech: hermesVM.connectionState == .speaking
                    ? { hermesVM.interruptSpeech() } : nil
            )
        }
    }

    private var pendingUserText: String {
        guard hermesVM.connectionState == .processing else { return "" }
        return hermesVM.lastTranscript
    }

    private var conversationActivity: AssistantConversationActivity {
        switch hermesVM.connectionState {
        case .processing:
            return .processing("Thinking…")
        case .speaking:
            return .speaking(speakingLabel)
        default:
            return .idle
        }
    }

    private var speakingLabel: String {
        if hermesVM.audio.isUsingBluetoothInput {
            let device = hermesVM.micSource == .headset ? "headset" : "glasses"
            return "\(assistantName) speaking through \(device) - tap to stop"
        }
        return "\(assistantName) is speaking - tap to stop"
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            HermesLockup(height: 26, showsSuffix: true)

            VStack(spacing: 8) {
                Text(emptyStateTitle)
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)
                    .multilineTextAlignment(.center)

                Text(emptyStateBody)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            switch glassesSetupState {
            case .ready, .phoneChosen:
                EmptyView()
            case .notPaired:
                HermesPrimaryButton(title: "Connect Glasses") {
                    wearablesVM.connectGlasses()
                }
                .padding(.horizontal, 24)
                Text("You'll finish pairing in the Meta AI app.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            case .pairedButUnreachable:
                // Already registered: offering "Connect Glasses" here just
                // produced "User is already registered". Re-pairing lives in
                // Settings, so send them there.
                HermesPrimaryButton(title: "Manage glasses", systemImage: "gearshape") {
                    openDevices()
                }
                .padding(.horizontal, 24)
                Text("Wake the glasses or put them on. If they still don't appear, re-pair them in Devices.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Quick actions

    /// The four feature screens, one tap from the conversation. Lens is
    /// the only one that needs the glasses; the rest read stored data.
    private var quickActions: some View {
        VStack(spacing: 6) {
            // Grab handle: the row is the top of a drawer, not the whole
            // set. Dragging up opens everything.
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 4)
                .contentShape(Rectangle().inset(by: -12))
                .onTapGesture { showAppDrawer = true }

            HStack(spacing: 8) {
                // Record is an action, not a screen, so it is deliberately
                // NOT a HermesApp - it has no presentation and nothing to
                // open. It sits here because this row is where people look
                // for features, and recording a conversation used to be
                // reachable only from a chip that appeared after a voice
                // session was already running.
                if hermesVM.socialNotesEnabled {
                    recordQuickAction
                }
                ForEach(HermesAppRegistry.pinned) { app in
                    quickAction(app)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -20 { showAppDrawer = true }
                }
        )
    }

    /// Why this app can't be opened right now, or nil. Stated in the drawer
    /// instead of letting the tap fail.
    private func unavailableReason(_ app: HermesApp) -> String? {
        if app.capabilities.contains(.vision), !hermesVM.canStartSession {
            return "Needs a camera - no glasses, and phone mode is off."
        }
        return nil
    }

    private func open(_ app: HermesApp) {
        switch app.id {
        case "lens": showLens = true
        case "people": showPeople = true
        case "map": showMap = true
        case "log": showObjectLog = true
        default: break
        }
    }

    /// Start/stop a conversation capture from a cold start.
    ///
    /// `toggleConversationCapture` brings up the microphone itself when
    /// nothing is running, so this tile never needs a session first.
    private var recordQuickAction: some View {
        Button {
            hermesVM.toggleConversationCapture()
        } label: {
            VStack(spacing: 5) {
                Image(
                    systemName: hermesVM.conversationCaptureActive
                        ? "stop.circle.fill" : "waveform.circle"
                )
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(
                    hermesVM.conversationCaptureActive ? .red : HermesTheme.accent
                )
                Text(hermesVM.conversationCaptureActive ? "Stop" : "Record")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HermesTheme.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                hermesVM.conversationCaptureActive
                    ? Color.red.opacity(0.12) : HermesTheme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func quickAction(_ app: HermesApp) -> some View {
        let blocked = unavailableReason(app) != nil
        return quickAction(app.title, icon: app.systemImage, enabled: !blocked) {
            open(app)
        }
    }

    private func quickAction(
        _ title: String,
        icon: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(HermesTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HermesTheme.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                HermesTheme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: - Bottom Bar (waveform + End / Start)

    private var bottomBar: some View {
        AssistantSessionBar(
            isRunning: hermesVM.connectionState != .disconnected,
            micLevel: hermesVM.micLevel,
            statusLabel: bottomStatusLabel,
            isError: isErrorState,
            darkChrome: showsPhoneModeStage,
            startTitle: startButtonTitle,
            canStart: hermesVM.canStartSession,
            startNote: startButtonNote,
            statusTapHint: "Switch microphone source",
            onStart: {
                Task { await hermesVM.startSession() }
            },
            onStatusTap: {
                Task { await hermesVM.toggleMicSource() }
            },
            onEnd: {
                hermesVM.endSession()
            }
        )
    }

    private var startButtonTitle: String { "Start listening" }

    /// Only says something the toggle above doesn't already say.
    private var startButtonNote: String? {
        if !hermesVM.canStartSession {
            return "No glasses, and phone mode is off. Turn it on in Settings → Devices."
        }
        // Glasses chosen but unreachable: the fallback is about to happen and
        // the user should not be surprised by it.
        if hermesVM.phoneModePreference != .always, !hermesVM.glassesAvailable {
            return "Glasses aren't reachable - this iPhone will be the eye."
        }
        return nil
    }

    private var isErrorState: Bool {
        if case .error = hermesVM.connectionState { return true }
        return false
    }

    /// State line under the waveform. Also names the mic, since tapping
    /// here switches it.
    private var bottomStatusLabel: String {
        // The note capture overrides the generic states - it's the one time
        // the user needs to know exactly what's being listened for.
        if hermesVM.awaitingEncounterNote {
            return "Say a note about this person"
        }
        let mic = "\(hermesVM.micSource.shortLabel) mic · tap to switch"
        switch hermesVM.connectionState {
        case .disconnected: return mic
        case .connecting: return "Connecting…"
        case .listening, .recording:
            return hermesVM.phoneModeActive
                ? "Listening · phone mode" : "Listening · \(mic)"
        case .processing: return "Thinking…"
        case .speaking: return "\(assistantName) speaking"
        case .error(let msg): return msg
        }
    }

    // MARK: - Helpers

    /// Who the user is talking to, per the selected backend
    private var assistantName: String {
        hermesVM.backend == .direct ? hermesVM.directProvider.displayName : "Hermes"
    }
}

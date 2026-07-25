//
// OnboardingView.swift
//
// First launch, three steps (design 1d, retargeted for turn 5): pair the
// glasses or choose the iPhone, grant what Hermes needs, then start.
//
// Bridge setup is deliberately absent - Direct API is the default brain now,
// so a first-time user should never have to hear the word "WebSocket".
// It's all still there under Settings → Assistant for whoever wants it.
//
// Shown once, gated on `onboarding_complete`. A denial does not trap the
// user: step 2 warns and offers Settings, but Continue still works, because
// a person who said no to the mic is allowed to look around the app.
//

import SwiftUI

struct OnboardingView: View {
    let wearablesVM: WearablesViewModel
    let hermesVM: HermesSessionViewModel
    let permissions: PermissionsCoordinator
    /// Dismiss and (optionally) start a session straight away.
    let onFinish: (_ startSession: Bool) -> Void

    @State private var step = 0
    @State private var requesting = false

    private static let stepCount = 3

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .background(HermesTheme.canvas.ignoresSafeArea())
        .tint(HermesTheme.accent)
        // Pairing finishes in the Meta AI app and comes back asynchronously;
        // when it lands, move on rather than making the user tap again.
        .onChange(of: wearablesVM.registrationState) { _, new in
            if new == .registered, step == 0 {
                withAnimation { step = 1 }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: glassesStep
        case 1: permissionsStep
        default: readyStep
        }
    }

    // MARK: - Step 1: glasses (or not)

    private var glassesStep: some View {
        VStack(spacing: 24) {
            Spacer()

            HermesLockup(height: 30, showsSuffix: true)

            VStack(spacing: 8) {
                Text("Connect your glasses")
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)
                    .multilineTextAlignment(.center)
                Text("Hermes talks to you through your Meta Ray-Ban glasses - mic, speaker, and camera.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if wearablesVM.registrationState == .registering {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for the Meta AI app…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 2: permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("What Hermes needs")
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)
                Text("Three permissions, asked once. Nothing is uploaded to set them up.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HermesCard(horizontalInset: 0) {
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element.id) { index, kind in
                    if index > 0 { HermesDivider() }
                    permissionRow(kind)
                }
                // The glasses camera is a Meta AI grant, not an iOS one, and
                // it only exists once glasses are paired.
                if wearablesVM.registrationState == .registered {
                    HermesDivider()
                    glassesCameraRow
                }
            }

            if permissions.hasDenial {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Something was declined. Hermes still opens, but the features that need it stay off until you change it in Settings.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") {
                        permissions.openSystemSettings()
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glassesCameraRow: some View {
        HStack(spacing: 12) {
            HermesIconTile(systemName: "eyeglasses", size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Glasses camera")
                        .font(.system(size: 16, weight: .semibold))
                    HermesBadge(text: "Meta AI")
                }
                Text("Granted in the Meta AI app. Without it the glasses take no pictures.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if hermesVM.cameraPermissionGranted == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(HermesTheme.online)
            } else {
                Text("Needed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let state = permissions.state(of: kind)
        return HStack(spacing: 12) {
            HermesIconTile(systemName: kind.systemImage, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.title)
                        .font(.system(size: 16, weight: .semibold))
                    if !kind.isEssential {
                        HermesBadge(text: "Phone mode")
                    }
                }
                Text(kind.reason)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(HermesTheme.online)
            case .denied:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(HermesTheme.destructive)
            case .notDetermined:
                Text(state.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Step 3: ready

    private var readyStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Circle()
                .fill((ready ? HermesTheme.online : HermesTheme.accent).opacity(0.15))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: ready ? "checkmark" : "exclamationmark")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(ready ? HermesTheme.online : HermesTheme.accent)
                }

            VStack(spacing: 8) {
                Text(ready ? "You're set" : "Almost there")
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)
                Text(readySubtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            HermesCard(horizontalInset: 0) {
                checkRow(
                    granted: "Glasses paired",
                    otherwise: "Phone mode - this iPhone is the eye",
                    done: wearablesVM.registrationState == .registered
                )
                HermesDivider()
                permissionCheckRow(.microphone, granted: "Microphone allowed",
                                   denied: "Microphone declined - voice is off")
                HermesDivider()
                permissionCheckRow(.speechRecognition, granted: "Speech recognition allowed",
                                   denied: "Speech declined - no transcription")
                HermesDivider()
                permissionCheckRow(.camera, granted: "Camera allowed",
                                   denied: "Camera declined - no phone-mode eye")
            }

            Text("The glasses camera is granted separately, on your first photo, via the Meta AI app.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    /// Everything the voice loop needs is granted.
    private var ready: Bool { permissions.essentialsGranted }

    private var readySubtitle: String {
        if !ready {
            return "Hermes needs the microphone and speech recognition to hear you. You can allow them in Settings."
        }
        return wearablesVM.registrationState == .registered
            ? "Your glasses are paired and Hermes can hear you."
            : "No glasses yet - Hermes will use this iPhone as the eye until you pair some."
    }

    private func checkRow(
        granted: String, otherwise: String, done: Bool,
        icon: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon ?? (done ? "checkmark.circle.fill" : "minus.circle"))
                .font(.system(size: 18))
                .foregroundStyle(done ? HermesTheme.online : Color.secondary)
            Text(done ? granted : otherwise)
                .font(.system(size: 15))
                .foregroundStyle(done ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Three outcomes, three wordings. A permission nobody has been asked
    /// about is not the same as one that was refused.
    private func permissionCheckRow(
        _ kind: PermissionKind, granted: String, denied: String
    ) -> some View {
        let state = permissions.state(of: kind)
        return checkRow(
            granted: granted,
            otherwise: state == .denied ? denied : "\(kind.title) not asked yet",
            done: state == .granted,
            icon: state == .denied ? "xmark.circle.fill" : nil
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 14) {
            primaryButton

            if step == 0 {
                Button("Use this iPhone instead") {
                    withAnimation { step = 1 }
                }
                .font(.system(size: 15, weight: .semibold))
                Text("Phone mode uses the iPhone camera and shows a simulated lens on screen.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step
                              ? HermesTheme.accent : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case 0:
            HermesPrimaryButton(
                title: wearablesVM.registrationState == .registering
                    ? "Connecting…" : "Connect Glasses",
                enabled: wearablesVM.registrationState != .registering
            ) {
                wearablesVM.connectGlasses()
            }
        case 1:
            if permissions.essentialsDecided {
                HermesPrimaryButton(title: "Continue") {
                    withAnimation { step = 2 }
                }
            } else {
                HermesPrimaryButton(
                    title: requesting ? "Asking…" : "Allow access",
                    enabled: !requesting
                ) {
                    Task {
                        requesting = true
                        await permissions.requestAll()
                        if wearablesVM.registrationState == .registered {
                            await hermesVM.ensureGlassesCameraAfterPairing()
                        }
                        requesting = false
                        if permissions.essentialsDecided {
                            withAnimation { step = 2 }
                        }
                    }
                }
            }
        default:
            if ready {
                HermesPrimaryButton(title: "Start Session", systemImage: "mic") {
                    onFinish(true)
                }
                Button("Not now") { onFinish(false) }
                    .font(.system(size: 15, weight: .semibold))
            } else {
                HermesPrimaryButton(title: "Open Settings", systemImage: "gearshape") {
                    permissions.openSystemSettings()
                }
                Button("Continue anyway") { onFinish(false) }
                    .font(.system(size: 15, weight: .semibold))
            }
        }
    }
}

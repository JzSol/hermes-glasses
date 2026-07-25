//
// HermesGlassesApp.swift
// Hermes Glasses - Talk to Hermes AI from Meta Ray-Ban glasses
//
// Main entry point. Configures the Meta Wearables DAT SDK, sets up
// audio capture from the glasses, and connects to Hermes Agent for
// real-time voice conversation.
//

import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct HermesGlassesApp: App {
    @State private var wearablesViewModel: WearablesViewModel
    @State private var hermesSessionViewModel: HermesSessionViewModel
    @State private var permissions = PermissionsCoordinator()

    /// First launch runs the three-step wizard (glasses → permissions →
    /// ready) so nobody meets a bare system dialog with no explanation.
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    // Light/dark override, applied to the whole window (see AppearanceMode).
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw =
        AppearanceMode.system.rawValue
    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init() {
        // Step 1: Configure the DAT SDK once at launch
        do {
            try Wearables.configure()
        } catch {
            #if DEBUG
            NSLog("[HermesGlasses] Failed to configure Wearables SDK: \(error)")
            #endif
        }

        #if DEBUG
        // Enable MockDeviceKit for testing without physical glasses
        if ProcessInfo.processInfo.arguments.contains("--mock-device") {
            MockDeviceKit.shared.enable(
                config: MockDeviceKitConfig(initiallyRegistered: false)
            )
        }
        #endif

        let wearables = Wearables.shared
        self._wearablesViewModel = State(
            wrappedValue: WearablesViewModel(wearables: wearables)
        )
        self._hermesSessionViewModel = State(
            wrappedValue: HermesSessionViewModel(wearables: wearables)
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                ContentView(
                    wearablesVM: wearablesViewModel,
                    hermesVM: hermesSessionViewModel
                )
                // Handle Meta AI URL callback after registration
                .onOpenURL { url in
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
                .alert("Hermes Error", isPresented: $hermesSessionViewModel.showError) {
                    Button("OK") { hermesSessionViewModel.dismissError() }
                } message: {
                    Text(hermesSessionViewModel.errorMessage)
                }
            }
            // A cover, not a sibling: as a sibling it laid out UNDER the
            // session screen, leaving half the app visible above it.
            .fullScreenCover(isPresented: Binding(
                get: { wearablesViewModel.registrationState == .registering },
                set: { _ in }
            )) {
                RegistrationInProgressView(viewModel: wearablesViewModel)
            }
            // Force light/dark for the whole window (sheets included).
            .preferredColorScheme(appearance.colorScheme)
            .fullScreenCover(isPresented: Binding(
                get: { !onboardingComplete },
                set: { onboardingComplete = !$0 }
            )) {
                OnboardingView(
                    wearablesVM: wearablesViewModel,
                    hermesVM: hermesSessionViewModel,
                    permissions: permissions
                ) { startSession in
                    onboardingComplete = true
                    if startSession {
                        Task { await hermesSessionViewModel.startSession() }
                    }
                }
            }
        }
    }
}

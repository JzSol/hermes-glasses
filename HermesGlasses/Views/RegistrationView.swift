//
// RegistrationView.swift
//
// Shown full-screen while the Meta AI companion app completes pairing.
//
// It used to be a plain sibling view in the app root's Group, which laid it
// out UNDER the session screen - half the app visible above it, the status
// bar colliding with the header. It is a cover now, and wears the Hermes
// palette rather than stock system blue.
//

import SwiftUI

struct RegistrationInProgressView: View {
    let viewModel: WearablesViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            HermesLockup(height: 26, showsSuffix: true)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(HermesTheme.accent.opacity(0.12))
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 44))
                        .foregroundStyle(HermesTheme.accent)
                }

            VStack(spacing: 8) {
                Text("Connect your glasses")
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)
                    .multilineTextAlignment(.center)
                Text("Follow the prompts in the Meta AI app to register your Ray-Ban glasses.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for Meta AI…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Cancel") {
                viewModel.disconnectGlasses()
            }
            .font(.system(size: 16, weight: .semibold))
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.canvas.ignoresSafeArea())
        .tint(HermesTheme.accent)
    }
}

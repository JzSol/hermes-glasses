//
// LookupView.swift
//
// The Lookup app's screen: live feed with person boxes, a hold ring on
// whoever the wearer is facing, and a card per person looked up - badge
// name plus what the web found. Styled like LensView (4c chrome): fixed
// warm black, one terracotta accent.
//

import SwiftUI

struct LookupView: View {
    @State private var model: LookupViewModel
    @Environment(\.dismiss) private var dismiss

    init(hermesVM: HermesSessionViewModel) {
        _model = State(initialValue: LookupViewModel(hermesVM: hermesVM))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            feed
            resultArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensChrome.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HermesScreenTitle(text: "LOOKUP")
                Text(model.errorBanner ?? model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(model.errorBanner == nil
                        ? HermesTheme.cream.opacity(0.5)
                        : HermesTheme.destructive)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if isBusy {
                ProgressView()
                    .tint(HermesTheme.accentLight)
                    .scaleEffect(0.8)
            }

            HermesChromePill(title: "Done", prominent: true) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var isBusy: Bool {
        switch model.phase {
        case .verifying, .reading, .searching: return true
        default: return false
        }
    }

    // MARK: - Live feed

    @ViewBuilder
    private var feed: some View {
        Group {
            if let image = model.feedImage {
                GeometryReader { geo in
                    let fitted = fittedRect(imageSize: image.size, in: geo.size)
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)

                        personOverlay(in: fitted)
                    }
                }
            } else if model.needsGlassesCameraGrant {
                VStack(spacing: 14) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 34))
                        .foregroundStyle(HermesTheme.cream.opacity(0.4))
                    Text("The glasses camera isn't allowed yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HermesTheme.cream)
                    Text("Meta AI grants this separately from iOS. It only has to be done once.")
                        .font(.system(size: 13))
                        .foregroundStyle(HermesTheme.cream.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        Task { await model.grantGlassesCamera() }
                    } label: {
                        Text("Allow camera")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(HermesTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .overlay {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(HermesTheme.accentLight)
                            Text(model.statusText)
                                .font(.system(size: 13))
                                .foregroundStyle(HermesTheme.cream.opacity(0.5))
                                .multilineTextAlignment(.center)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensStage)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
    }

    /// Where the aspect-fit image lands in the container (see LensView).
    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale,
                          height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// Person boxes: terracotta on the one being held, dashed cream on the
    /// rest, and a ring that fills as the hold accumulates.
    @ViewBuilder
    private func personOverlay(in fitted: CGRect) -> some View {
        Canvas { context, _ in
            for rect in model.personBoxes {
                let box = CGRect(
                    x: fitted.minX + rect.minX * fitted.width,
                    y: fitted.minY + rect.minY * fitted.height,
                    width: rect.width * fitted.width,
                    height: rect.height * fitted.height
                )
                if rect == model.targetBox {
                    context.stroke(
                        Path(roundedRect: box, cornerRadius: 8),
                        with: .color(HermesTheme.accent),
                        lineWidth: 2.5
                    )
                } else {
                    context.stroke(
                        Path(roundedRect: box, cornerRadius: 8),
                        with: .color(Color.white.opacity(0.4)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                }
            }
        }
        .allowsHitTesting(false)

        if let target = model.targetBox {
            holdRing
                .position(
                    x: fitted.minX + target.midX * fitted.width,
                    y: fitted.minY + target.minY * fitted.height + 40
                )
        }
    }

    private var holdRing: some View {
        ZStack {
            Circle()
                .stroke(HermesTheme.cream.opacity(0.25), lineWidth: 4)
                .frame(width: 52, height: 52)
            Circle()
                .trim(from: 0, to: model.holdProgress)
                .stroke(
                    HermesTheme.accent,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 52, height: 52)
                .animation(.linear(duration: 0.1), value: model.holdProgress)
            Image(systemName: "person.text.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(HermesTheme.cream.opacity(0.8))
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .allowsHitTesting(false)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let latest = model.hits.first {
                resultCard(latest)
            } else {
                Text("Stand facing someone within a couple of meters. When the ring fills, the web is searched for who they are - face first, badge as fallback.")
                    .font(.system(size: 12))
                    .foregroundStyle(HermesTheme.cream.opacity(0.4))
                    .padding(.horizontal, 20)
            }

            if model.hits.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.hits.dropFirst()) { hit in
                            earlierHit(hit)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: model.hits.count)
    }

    private func resultCard(_ hit: LookupHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(uiImage: hit.image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(hit.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(HermesTheme.cream)
                Text(hit.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(HermesTheme.cream.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            HermesTheme.cream.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(.horizontal, 16)
    }

    private func earlierHit(_ hit: LookupHit) -> some View {
        VStack(spacing: 4) {
            Image(uiImage: hit.image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(hit.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(HermesTheme.cream.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: 64)
    }
}

//
// LensView.swift
//
// Object Snap: live glasses-camera feed with YOLO boxes, a center
// reticle that fills while you hold an object under it, and a strip of
// what it has logged. Stream runs only while this view is on screen.
//
// Styled to screen 4c: warm-black chrome (fixed, not adaptive - the
// camera feed carries the frame), terracotta reticle and detection box
// on the dwell target, and snap tiles that carry look-time so the strip
// reads as attention, not just thumbnails.
//

import SwiftUI

struct LensView: View {
    @State private var model: LensViewModel
    @State private var selectedEntry: LensLogEntry?
    @State private var shareItem: ShareItem?
    @State private var showObjectLog = false
    @Environment(\.dismiss) private var dismiss

    private let hermesVM: HermesSessionViewModel

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
        _model = State(initialValue: LensViewModel(hermesVM: hermesVM))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            feed
            gazeSlider
            snapStrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensChrome.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .sheet(item: $selectedEntry) { entry in
            entryDetail(entry)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showObjectLog, onDismiss: { model.resumeStreaming() }) {
            ObjectLogView(hermesVM: hermesVM)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HermesScreenTitle(text: "LENS")
                Text(model.errorBanner ?? model.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(model.errorBanner == nil
                        ? HermesTheme.cream.opacity(0.5)
                        : HermesTheme.destructive)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if model.isStreaming {
                Text("\(model.fps) fps")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HermesTheme.cream.opacity(0.4))
            }

            Button {
                exportPDF()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HermesTheme.cream)
                    .frame(width: 30, height: 30)
                    .background(HermesTheme.cream.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.loggedObjectCount == 0)
            .opacity(model.loggedObjectCount == 0 ? 0.4 : 1)

            HermesChromePill(title: "History") {
                model.pauseStreaming()
                showObjectLog = true
            }

            HermesChromePill(title: "Done", prominent: true) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Live feed + overlay

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

                        detectionOverlay(in: fitted)
                        reticle
                            .position(x: fitted.midX, y: fitted.midY)
                        captureOverlay
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
        // The stage fills the space between header and controls and the
        // frame is aspect-fit inside it (design 4c) - `fittedRect` maps
        // detections into wherever the image actually lands, so the
        // letterboxing costs nothing in accuracy.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HermesTheme.lensStage)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
    }

    /// Where the aspect-fit image actually lands inside the container -
    /// detection rects are normalized to the IMAGE, so boxes must map
    /// into this rect, not the container.
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

    private func detectionOverlay(in fitted: CGRect) -> some View {
        Canvas { context, _ in
            for detection in model.detections {
                let r = detection.rect
                let box = CGRect(
                    x: fitted.minX + r.minX * fitted.width,
                    y: fitted.minY + r.minY * fitted.height,
                    width: r.width * fitted.width,
                    height: r.height * fitted.height
                )
                let isTarget = detection.label == model.targetLabel
                // Terracotta on the object being looked at, dashed cream
                // on everything else - one accent, one focus (design 4c).
                if isTarget {
                    context.stroke(
                        Path(roundedRect: box, cornerRadius: 6),
                        with: .color(HermesTheme.accent),
                        lineWidth: 2.5
                    )
                    let tag = CGRect(
                        x: box.minX, y: max(box.minY - 16, 0),
                        width: 62, height: 16
                    )
                    context.fill(
                        Path(roundedRect: tag, cornerRadius: 3),
                        with: .color(HermesTheme.accent)
                    )
                } else {
                    context.stroke(
                        Path(roundedRect: box, cornerRadius: 6),
                        with: .color(Color.white.opacity(0.5)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                }
                let label = Text(" \(detection.label) ")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isTarget ? .white : Color.white.opacity(0.6))
                context.draw(
                    label,
                    at: CGPoint(x: box.minX + 4, y: max(box.minY - 8, 8)),
                    anchor: .leading
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// Shutter flash + status pill for the snap moment ("Taking a pic…"
    /// then "Cropping…"), driven by the model's capture stage.
    @ViewBuilder
    private var captureOverlay: some View {
        if let stage = model.captureStage {
            ZStack {
                if stage == .flash {
                    Rectangle()
                        .fill(.white)
                        .opacity(0.65)
                        .transition(.opacity)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: stage == .flash
                            ? "camera.fill" : "scissors")
                        Text(stage == .flash ? "Taking a pic…" : "Cropping…")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(HermesTheme.ink.opacity(0.7), in: Capsule())
                    .padding(.bottom, 14)
                }
            }
            .animation(.easeOut(duration: 0.3), value: stage)
            .allowsHitTesting(false)
        }
    }

    /// Center reticle: a ring that fills clockwise as dwell accumulates.
    private var reticle: some View {
        ZStack {
            Circle()
                .stroke(HermesTheme.cream.opacity(0.25), lineWidth: 4)
                .frame(width: 68, height: 68)
            Circle()
                .trim(from: 0, to: model.dwellProgress)
                .stroke(
                    HermesTheme.accent,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 68, height: 68)
                .animation(.linear(duration: 0.1), value: model.dwellProgress)
            Circle()
                .fill(HermesTheme.cream)
                .frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
    }

    // MARK: - Gaze duration

    /// Live control over how long a look must last before it snaps. Drag it
    /// while pointing at an object and the reticle fills at the new speed.
    private var gazeSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 13))
                .foregroundStyle(HermesTheme.cream.opacity(0.55))
            Slider(
                value: $model.dwellSeconds,
                in: LensViewModel.minDwell...LensViewModel.maxDwell,
                step: 0.5
            )
            .tint(HermesTheme.accent)
            Text(String(format: "gaze %.1fs", model.dwellSeconds))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(HermesTheme.cream.opacity(0.55))
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Snap strip

    /// Aggregated per-object tiles: crop, name, total look-time and look
    /// count. This is the same data the Object Log and the PDF export
    /// carry, so what you see mid-session matches the report.
    @ViewBuilder
    private var snapStrip: some View {
        let entries = model.logEntries

        VStack(alignment: .leading, spacing: 8) {
            if entries.isEmpty {
                Text(String(
                    format: "Hold the ring on an object for %.1f seconds to snap it",
                    model.dwellSeconds
                ))
                .font(.system(size: 12))
                .foregroundStyle(HermesTheme.cream.opacity(0.4))
                .padding(.horizontal, 20)
                .frame(height: 96, alignment: .top)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(entries) { entry in
                            Button {
                                selectedEntry = entry
                            } label: {
                                snapTile(entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 96)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .animation(.snappy, value: model.loggedObjectCount)
    }

    private func snapTile(_ entry: LensLogEntry) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = entry.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.clear.overlay {
                        Text(entry.label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(HermesTheme.cream.opacity(0.45))
                    }
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(HermesTheme.mediaPlaceholder.opacity(0.25))
            )
            .overlay {
                // The object currently under the reticle wears the accent.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        entry.label == model.targetLabel
                            ? HermesTheme.accent.opacity(0.8) : .clear,
                        lineWidth: 1.5
                    )
            }

            Text("\(LensPDFRenderer.timeLabel(entry.totalLookTime)) · \(entry.lookCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(HermesTheme.cream.opacity(0.45))
        }
        .frame(width: 72)
    }

    private func entryDetail(_ entry: LensLogEntry) -> some View {
        VStack(spacing: 14) {
            if let image = entry.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 3) {
                Text(entry.label)
                    .font(.system(size: 20, weight: .bold))
                Text("\(LensPDFRenderer.timeLabel(entry.totalLookTime)) · \(entry.lookCount) look\(entry.lookCount == 1 ? "" : "s")")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
        .presentationDetents([.medium, .large])
    }

    private func exportPDF() {
        let rows = model.logEntries.map { entry in
            LensPDFRenderer.Row(
                label: entry.label, totalLookTime: entry.totalLookTime,
                lookCount: entry.lookCount, image: entry.image
            )
        }
        let title = "Object Log — " + Date().formatted(
            date: .abbreviated, time: .shortened
        )
        let data = LensPDFRenderer.makePDF(title: title, rows: rows)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("object-log.pdf")
        try? data.write(to: url, options: .atomic)
        shareItem = ShareItem(url: url)
    }
}

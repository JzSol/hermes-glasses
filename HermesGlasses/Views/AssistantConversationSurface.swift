//
// AssistantConversationSurface.swift
//
// The chat and live-session presentation shared by HermesGlasses and Adam.
// It accepts values and closures only; it never owns audio, speech, camera,
// wearable, or bridge services.
//

import SwiftUI
import UIKit

private let assistantUserBubbleShape = UnevenRoundedRectangle(
    topLeadingRadius: 20,
    bottomLeadingRadius: 20,
    bottomTrailingRadius: 6,
    topTrailingRadius: 20
)

struct AssistantConversationSurface: View {
    let turns: [ConversationTurn]
    var defaultPhotoSource: String = "Camera"
    var pendingUserText: String = ""
    var liveTranscript: String = ""
    var liveTranscriptLabel: String = "Transcribing…"
    var streamingResponse: String = ""
    var replyChoices: [AssistantReplyChoice] = []
    var activity: AssistantConversationActivity = .idle
    var onSendNow: (() -> Void)?
    var onChooseReply: ((AssistantReplyChoice) -> Void)?
    var onInterruptSpeech: (() -> Void)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(turns) { turn in
                        AssistantTurnBubble(
                            turn: turn,
                            defaultPhotoSource: defaultPhotoSource
                        )
                    }

                    if !pendingUserText.isEmpty {
                        AssistantUserBubble(text: pendingUserText)
                    }

                    if !liveTranscript.isEmpty {
                        liveTranscriptBubble
                    }

                    if !streamingResponse.isEmpty {
                        AssistantResponseBubble(text: streamingResponse)
                            .accessibilityLabel("Assistant response: \(streamingResponse)")
                    }

                    if !replyChoices.isEmpty {
                        choiceChips
                    }

                    activityIndicator

                    Color.clear
                        .frame(height: 1)
                        .id("assistant-conversation-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: turns.count) { _, _ in
                withAnimation {
                    proxy.scrollTo("assistant-conversation-bottom", anchor: .bottom)
                }
            }
            .onChange(of: liveTranscript) { _, _ in
                proxy.scrollTo("assistant-conversation-bottom", anchor: .bottom)
            }
            .onChange(of: streamingResponse) { _, _ in
                proxy.scrollTo("assistant-conversation-bottom", anchor: .bottom)
            }
        }
    }

    private var liveTranscriptBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 4) {
                Text(liveTranscript)
                    .font(.body)
                    .kerning(-0.3)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1), in: assistantUserBubbleShape)
                    .overlay(
                        assistantUserBubbleShape
                            .strokeBorder(
                                Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                            )
                    )

                Text(liveTranscriptLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if let onSendNow {
                Button(action: onSendNow) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(HermesTheme.accent)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)
                .accessibilityLabel("Send now")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var choiceChips: some View {
        AssistantFlowRow(spacing: 8) {
            ForEach(replyChoices) { choice in
                Button {
                    onChooseReply?(choice)
                } label: {
                    Text(choice.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HermesTheme.accentOnCard)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(HermesTheme.accent.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(
                                HermesTheme.accent.opacity(0.3), lineWidth: 1
                            )
                        }
                }
                .buttonStyle(.plain)
                .disabled(onChooseReply == nil)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply choices")
    }

    @ViewBuilder
    private var activityIndicator: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .processing(let label):
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        case .speaking(let label):
            Button {
                onInterruptSpeech?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .symbolEffect(.variableColor.iterative)
                    Text(label)
                        .font(.caption2.weight(.semibold))
                    if onInterruptSpeech != nil {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 12))
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(onInterruptSpeech == nil)
            .padding(.horizontal, 4)
        }
    }
}

struct AssistantUserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.body)
                .kerning(-0.3)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(HermesTheme.accent, in: assistantUserBubbleShape)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }
}

struct AssistantResponseBubble: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(.body)
                .kerning(-0.3)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    HermesTheme.card,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: 6,
                        bottomTrailingRadius: 20,
                        topTrailingRadius: 20
                    )
                )
                .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            Spacer(minLength: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Assistant: \(text)")
    }
}

struct AssistantTurnBubble: View {
    let turn: ConversationTurn
    var defaultPhotoSource: String = "Camera"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let photoData = turn.photo,
               let image = UIImage(data: photoData) {
                HStack {
                    Spacer()
                    AssistantPhotoCard(
                        image: image,
                        source: turn.photoSource ?? defaultPhotoSource
                    )
                }
            }

            AssistantUserBubble(text: turn.userText)
            AssistantResponseBubble(text: turn.agentText)
        }
    }
}

/// Captured attachment with the same camera-source caption used by Hermes.
struct AssistantPhotoCard: View {
    let image: UIImage
    var source: String = "Camera"

    var body: some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 200, height: 130)
                .clipped()

            HStack(spacing: 5) {
                Image(systemName: "camera")
                    .font(.system(size: 10, weight: .semibold))
                Text(source)
                    .font(.caption2.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HermesTheme.card)
        }
        .frame(width: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo from \(source)")
    }
}

/// Shared live-session bar: waveform, explicit state, contextual recovery,
/// and start/end controls. Session ownership remains in the supplied closures.
struct AssistantSessionBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isRunning: Bool
    let micLevel: Float
    let statusLabel: String
    var isError = false
    var darkChrome = false
    var startTitle = "Start listening"
    var canStart = true
    var startNote: String?
    var contextActionTitle: String?
    var contextActionIsDestructive = false
    var statusTapHint: String?
    var presentationPhase: AdamPresentationFeedbackPhase? = nil
    let onStart: () -> Void
    var onStatusTap: (() -> Void)?
    var onContextAction: (() -> Void)?
    let onEnd: () -> Void

    var body: some View {
        Group {
            if isRunning {
                listeningBar
            } else {
                VStack(spacing: 8) {
                    HermesPrimaryButton(
                        title: startTitle,
                        systemImage: "mic",
                        enabled: canStart,
                        action: onStart
                    )
                    if let startNote {
                        Text(startNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
            }
        }
    }

    private var listeningBar: some View {
        HStack(spacing: 12) {
            statusControl

            if let contextActionTitle, let onContextAction {
                Button(action: onContextAction) {
                    Text(contextActionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(
                            contextActionIsDestructive
                                ? HermesTheme.destructive
                                : HermesTheme.accentOnCard
                        )
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(
                            (contextActionIsDestructive
                                ? HermesTheme.destructive
                                : HermesTheme.accent).opacity(0.12),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            HermesDestructiveButton(title: "End", height: 40, action: onEnd)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                HermesDivider()
                (darkChrome
                    ? HermesTheme.cream.opacity(0.06)
                    : HermesTheme.card.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            phaseVisualizer
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant status")
        .accessibilityValue(statusLabel)
        .accessibilityAddTraits(.updatesFrequently)

        if let onStatusTap {
            Button(action: onStatusTap) { content }
                .buttonStyle(.plain)
                .accessibilityHint(statusTapHint ?? "")
        } else {
            content
        }
    }

    @ViewBuilder
    private var phaseVisualizer: some View {
        let accent = isError ? HermesTheme.destructive : HermesTheme.accent
        switch presentationPhase ?? .listening {
        case .listening, .hearingSpeech:
            WaveformView(level: micLevel, accent: accent, barCount: 22)
        case .paused:
            HStack(spacing: 7) {
                Image(systemName: "pause.circle.fill")
                Text("Still listening")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .frame(height: 28, alignment: .center)
        case .transcribing:
            HStack(spacing: 7) {
                Image(systemName: "waveform.and.mic")
                Text("Transcribing")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .frame(height: 28, alignment: .center)
        case .transcriptReady:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                Text("Transcript ready")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .frame(height: 28, alignment: .center)
        case .thinking, .preparingVoice:
            AdamThinkingPulseView(reduceMotion: reduceMotion, accent: accent)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(height: 28, alignment: .center)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(accent)
                .frame(height: 28, alignment: .center)
        case .idle, .connecting:
            WaveformView(level: 0, accent: accent, barCount: 22)
        }
    }

    private var statusColor: Color {
        if isError { return HermesTheme.destructive }
        return darkChrome ? HermesTheme.cream.opacity(0.5) : .secondary
    }
}

/// Wrapping horizontal stack shared by conversation choice chips.
struct AssistantFlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(
            width: maxWidth == .infinity ? x : maxWidth,
            height: y + lineHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Mic-level waveform: bars with the original Hermes sine envelope.
struct WaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Float
    let accent: Color
    var barCount: Int = 30

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<max(2, barCount), id: \.self) { i in
                let count = max(2, barCount)
                let env = sin(Double(i) / Double(count - 1) * .pi)
                let taper = 0.5 + 0.5 * env
                let resting = 5 + 11 * abs(sin(Double(i) * 2.7 + 1.3))
                Capsule()
                    .fill(accent.opacity(0.45 + 0.55 * env))
                    .frame(
                        width: 3,
                        height: max(3, resting * taper + 22 * amplitude * env)
                    )
            }
        }
        .frame(height: 28, alignment: .center)
        .animation(
            reduceMotion ? nil : .linear(duration: 0.12),
            value: level
        )
        .accessibilityHidden(true)
    }

    private var amplitude: Double {
        min(1.0, Double(level) * 10)
    }
}

private struct AdamThinkingPulseView: View {
    let reduceMotion: Bool
    let accent: Color
    @State private var isExpanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.18), lineWidth: 2)
                .scaleEffect(isExpanded ? 1.12 : 0.82)
            Circle()
                .fill(accent.opacity(0.78))
                .frame(width: 10, height: 10)
        }
        .frame(width: 42, height: 28)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isExpanded = true
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                isExpanded = false
            } else {
                withAnimation(
                    .easeInOut(duration: 1.1)
                        .repeatForever(autoreverses: true)
                ) {
                    isExpanded = true
                }
            }
        }
        .accessibilityHidden(true)
    }
}

//
// HermesDesign.swift
//
// The Hermes visual language, in one place: brand colours, the winged
// mark, the wordmark, and the handful of container primitives every
// screen is built from (grouped card, section header, icon tile, chip,
// pill button).
//
// Rules the design doc is strict about, so the primitives enforce them:
//   * ONE accent. Terracotta #C4622D and its shades - never a rainbow of
//     per-row iOS system colours.
//   * Warm neutrals. Cream canvas (#F7F5F2) and warm black (#1C1B1A),
//     not pure white/black greys.
//   * Grouped cards: white (warm black in dark), 22pt corners, 16pt
//     side margin, hairline dividers inside.
//
// Everything here is presentation only - no view models, no state.
//

import SwiftUI
import UIKit

// MARK: - Palette

extension Color {
    /// #RRGGBB literal, for transcribing design tokens verbatim.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Light/dark pair. The design ships both schemes, so most tokens
    /// carry two values rather than relying on system semantics.
    static func hermesAdaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

enum HermesTheme {
    // Accent family
    /// Terracotta accent from the design (#C4622D)
    static let accent = Color(hex: 0xC4622D)
    /// Darker terracotta for text on light fills (#96471A)
    static let accentDeep = Color(hex: 0x96471A)
    /// Link / tappable-label terracotta (#C05C21)
    static let accentLink = Color(hex: 0xC05C21)
    /// Light terracotta for glyphs on warm black (#E8996A)
    static let accentLight = Color(hex: 0xE8996A)
    /// Accent that stays legible in both schemes on a card
    static let accentOnCard = Color.hermesAdaptive(light: 0xC05C21, dark: 0xE8996A)

    // Neutrals
    /// Warm black used for hero cards and dark chrome (#1C1B1A)
    static let ink = Color(hex: 0x1C1B1A)
    /// Warm mid grey for supporting copy (#6E6A64)
    static let inkSoft = Color(hex: 0x6E6A64)
    /// Cream used for text on warm black (#F5F2EE)
    static let cream = Color(hex: 0xF5F2EE)

    // Surfaces
    /// Screen background - cream in light, warm black in dark
    static let canvas = Color.hermesAdaptive(light: 0xF7F5F2, dark: 0x141312)
    /// Grouped-list background, a touch deeper than `canvas`
    static let groupedCanvas = Color.hermesAdaptive(light: 0xEFEDEA, dark: 0x141312)
    /// Card / list-row fill
    static let card = Color.hermesAdaptive(light: 0xFFFFFF, dark: 0x1F1D1B)
    /// Placeholder fill behind thumbnails and empty media (#E5E1DB)
    static let mediaPlaceholder = Color.hermesAdaptive(light: 0xE5E1DB, dark: 0x2A2724)

    // Dark-chrome surfaces (Lens, phone-mode, HUD banners) - fixed, not adaptive:
    // these screens are always dark so the camera feed carries the frame.
    static let lensChrome = Color(hex: 0x141312)
    static let lensStage = Color(hex: 0x1B1A19)

    // Status
    static let online = Color(hex: 0x34C759)
    static let destructive = Color.hermesAdaptive(light: 0xE03026, dark: 0xFF6961)

    // Legacy aliases kept so existing call sites keep compiling.
    /// Neutral chip/bubble fill that adapts to light/dark
    static let chipFill = Color(uiColor: .tertiarySystemFill)
    /// Assistant bubble fill
    static let assistantBubble = Color.hermesAdaptive(light: 0xFFFFFF, dark: 0x26241F)

    /// Hairline between rows inside a grouped card
    static let hairline = Color.hermesAdaptive(light: 0x3C3C43, dark: 0xF5F2EE)
        .opacity(0.12)
}

// MARK: - Brand mark

/// The winged Hermes mark: two three-bar wings around a small diamond.
/// Transcribed from the design's SVG polygons on a 140x72 canvas and
/// scaled to whatever rect it is given (aspect ratio preserved).
struct HermesMark: Shape {
    private static let designSize = CGSize(width: 140, height: 72)

    private static let polygons: [[CGPoint]] = [
        [.init(x: 84, y: 54), .init(x: 132, y: 26), .init(x: 132, y: 44), .init(x: 84, y: 72)],
        [.init(x: 84, y: 28), .init(x: 132, y: 0), .init(x: 132, y: 18), .init(x: 84, y: 46)],
        [.init(x: 56, y: 54), .init(x: 8, y: 26), .init(x: 8, y: 44), .init(x: 56, y: 72)],
        [.init(x: 56, y: 28), .init(x: 8, y: 0), .init(x: 8, y: 18), .init(x: 56, y: 46)],
        [.init(x: 70, y: 55), .init(x: 77, y: 63), .init(x: 70, y: 71), .init(x: 63, y: 63)],
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(
            rect.width / Self.designSize.width,
            rect.height / Self.designSize.height
        )
        let drawn = CGSize(
            width: Self.designSize.width * scale,
            height: Self.designSize.height * scale
        )
        let originX = rect.minX + (rect.width - drawn.width) / 2
        let originY = rect.minY + (rect.height - drawn.height) / 2

        var path = Path()
        for polygon in Self.polygons {
            guard let first = polygon.first else { continue }
            path.move(to: CGPoint(x: originX + first.x * scale,
                                  y: originY + first.y * scale))
            for point in polygon.dropFirst() {
                path.addLine(to: CGPoint(x: originX + point.x * scale,
                                         y: originY + point.y * scale))
            }
            path.closeSubpath()
        }
        return path
    }
}

/// Mark + "HERMES" wordmark, the lockup that heads the session screens.
///
/// The design specifies Montserrat 800; no font file ships with the app,
/// so the wordmark uses the system face at `.heavy` with the same wide
/// tracking - the silhouette (heavy, wide-tracked, all caps) is what
/// carries the brand, not the exact typeface.
struct HermesLockup: View {
    var height: CGFloat = 16
    var tint: Color = HermesTheme.accent
    /// Adds a lighter "GLASSES" half, as on the full lockup.
    var showsSuffix: Bool = false

    var body: some View {
        HStack(spacing: height * 0.55) {
            HermesMark()
                .fill(tint)
                .frame(width: height * 1.95, height: height)

            HStack(spacing: 0) {
                Text("HERMES")
                    .font(.system(size: height, weight: .heavy))
                if showsSuffix {
                    Text("GLASSES")
                        .font(.system(size: height, weight: .light))
                }
            }
            .kerning(height * 0.06)
            .foregroundStyle(tint)
        }
        .accessibilityElement()
        .accessibilityLabel(showsSuffix ? "Hermes Glasses" : "Hermes")
    }
}

/// All-caps screen title in the wordmark's voice ("LENS", "PHONE MODE").
struct HermesScreenTitle: View {
    let text: String
    var size: CGFloat = 17
    var tint: Color = HermesTheme.cream

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .heavy))
            .kerning(1)
            .foregroundStyle(tint)
    }
}

// MARK: - Containers

/// A grouped card: white fill, 22pt corners, 16pt side margin. Rows go
/// inside separated by `HermesDivider`.
struct HermesCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    /// Side margin. Pass 0 inside a container that already insets its
    /// content, rather than cancelling this out with negative padding.
    var horizontalInset: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(
                HermesTheme.card,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .padding(.horizontal, horizontalInset)
    }
}

/// Hairline between rows inside a card - inset to match the design's
/// full-bleed dividers.
struct HermesDivider: View {
    var body: some View {
        Rectangle()
            .fill(HermesTheme.hairline)
            .frame(height: 0.5)
    }
}

/// Uppercase group caption above a card.
struct HermesSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 13))
            .foregroundStyle(HermesTheme.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
    }
}

/// Explanatory line under a card.
struct HermesSectionFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(HermesTheme.inkSoft.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 4)
    }
}

/// Section = header + card + footer, the unit every settings page repeats.
struct HermesSection<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                HermesSectionHeader(title: header)
            }
            HermesCard(content: content)
            if let footer {
                HermesSectionFooter(text: footer)
            }
        }
    }
}

// MARK: - Row furniture

/// The one-accent settings icon: a terracotta-tinted tile, never a
/// per-row system colour.
struct HermesIconTile: View {
    let systemName: String
    var size: CGFloat = 29
    var muted: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(muted
                ? Color.primary.opacity(0.08)
                : HermesTheme.accent.opacity(0.12))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(muted ? AnyShapeStyle(Color.secondary)
                                           : AnyShapeStyle(HermesTheme.accent))
            }
    }
}

/// Trailing chevron, matched to the design's 8x14 glyph.
struct HermesChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// A settings row: icon tile, title, optional trailing value, chevron.
struct HermesRow<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    var mutedIcon: Bool = false
    var subtitle: String? = nil
    var showsChevron: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                HermesIconTile(systemName: icon, muted: mutedIcon)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17))
                    .kerning(-0.43)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
            if showsChevron {
                HermesChevron()
            }
        }
        .padding(.horizontal, 16)
        // Vertical padding + a floor, so a one-line row is exactly 52pt
        // and a wrapped subtitle still breathes.
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

extension HermesRow where Trailing == HermesRowValue {
    init(
        _ title: String,
        icon: String? = nil,
        mutedIcon: Bool = false,
        subtitle: String? = nil,
        value: String? = nil,
        showsChevron: Bool = true
    ) {
        self.init(
            title: title, icon: icon, mutedIcon: mutedIcon, subtitle: subtitle,
            showsChevron: showsChevron,
            trailing: { HermesRowValue(value: value) }
        )
    }
}

struct HermesRowValue: View {
    let value: String?

    var body: some View {
        if let value {
            Text(value)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Chips & pills

/// Capability / status chip: small, terracotta-tinted, or grey when the
/// capability is absent ("No display", "Simulated display").
struct HermesChip: View {
    let text: String
    var available: Bool = true
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(available ? HermesTheme.accentOnCard : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                available
                    ? HermesTheme.accent.opacity(0.12)
                    : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
    }
}

/// Uppercase state badge ("Default", "Advanced", "Soon").
struct HermesBadge: View {
    let text: String
    var prominent: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(prominent ? HermesTheme.accentOnCard : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                prominent
                    ? HermesTheme.accent.opacity(0.14)
                    : Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}

/// Status capsule with a state dot - the header's "Glasses · 82%".
struct HermesStatusPill: View {
    let text: String
    var dot: Color? = nil
    /// Trailing SF Symbol - e.g. a snap count while a recording runs.
    /// Keeps counters in the app's own iconography instead of an emoji.
    var icon: String? = nil
    /// Terracotta-tinted (connected) vs neutral (everything else).
    var tinted: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tinted ? HermesTheme.accentOnCard : Color.secondary)
                .lineLimit(1)
                .fixedSize()
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tinted ? HermesTheme.accentOnCard : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            tinted
                ? HermesTheme.accent.opacity(0.1)
                : Color.secondary.opacity(0.12),
            in: Capsule()
        )
    }
}

/// Two-way segmented capsule: which eye Hermes is using. Explicit and
/// always visible, because inferring it and explaining the inference in
/// prose ("No glasses connected - the iPhone camera will be...") left
/// people unsure what the app was about to do.
struct HermesEyeToggle: View {
    @Binding var usesGlasses: Bool
    /// Glasses selected but something is wrong with them - unreachable, or
    /// missing the camera grant. Shown, not hidden.
    var glassesWarning: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            segment(
                title: "Glasses",
                systemImage: "eyeglasses",
                selected: usesGlasses,
                warns: usesGlasses && glassesWarning
            ) { usesGlasses = true }

            segment(
                title: "Phone",
                systemImage: "iphone",
                selected: !usesGlasses,
                warns: false
            ) { usesGlasses = false }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.14), in: Capsule())
        .animation(.snappy(duration: 0.2), value: usesGlasses)
    }

    private func segment(
        title: String,
        systemImage: String,
        selected: Bool,
        warns: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: warns ? "exclamationmark.triangle.fill" : systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(selected ? .white : Color.secondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                selected
                    ? AnyShapeStyle(warns ? HermesTheme.accentDeep : HermesTheme.accent)
                    : AnyShapeStyle(Color.clear),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Filled capsule button (Export PDF, Start Session).
struct HermesPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                enabled ? HermesTheme.accent : Color.secondary.opacity(0.4),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Tinted destructive capsule (End, Delete).
struct HermesDestructiveButton: View {
    let title: String
    var height: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: height > 44 ? 16 : 15, weight: .semibold))
                .foregroundStyle(HermesTheme.destructive)
                .padding(.horizontal, height > 44 ? 20 : 18)
                .frame(height: height)
                .background(HermesTheme.destructive.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Compact pill used on dark chrome (Lens "History" / "Done").
struct HermesChromePill: View {
    let title: String
    var prominent: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? HermesTheme.accentLight : HermesTheme.cream)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    prominent
                        ? HermesTheme.accent.opacity(0.25)
                        : HermesTheme.cream.opacity(0.1),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Hero cards

/// Warm-black hero card, used for the connected-device summary at the
/// top of Settings and Devices.
struct HermesDeviceCard<Accessory: View>: View {
    let title: String
    let status: String
    var dot: Color = HermesTheme.online
    var chips: [(label: String, available: Bool)] = []
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(HermesTheme.accent.opacity(0.18))
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 22))
                            .foregroundStyle(HermesTheme.accentLight)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .kerning(-0.3)
                        .foregroundStyle(HermesTheme.cream)
                    HStack(spacing: 6) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(status)
                            .font(.system(size: 13))
                            .foregroundStyle(HermesTheme.cream.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
                accessory()
            }

            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.label) { chip in
                        Text(chip.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(chip.available
                                ? HermesTheme.accentLight
                                : HermesTheme.cream.opacity(0.4))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                chip.available
                                    ? HermesTheme.accent.opacity(0.2)
                                    : HermesTheme.cream.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            HermesTheme.ink,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .padding(.horizontal, 16)
    }
}

extension HermesDeviceCard where Accessory == EmptyView {
    init(
        title: String,
        status: String,
        dot: Color = HermesTheme.online,
        chips: [(label: String, available: Bool)] = []
    ) {
        self.init(title: title, status: status, dot: dot, chips: chips,
                  accessory: { EmptyView() })
    }
}

/// Terracotta-tinted informational strip ("Stored on this iPhone only").
struct HermesNotice: View {
    let text: String
    var systemImage: String = "lock"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HermesTheme.accentOnCard)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HermesTheme.accentOnCard)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            HermesTheme.accent.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .padding(.horizontal, 16)
    }
}

/// One of the three numbers above the Object Log ("5 objects").
struct HermesStatTile: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .kerning(-0.4)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            HermesTheme.card,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

/// Attention bar: share of total look-time for one object.
struct HermesAttentionBar: View {
    /// 0...1
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(HermesTheme.accent.opacity(0.12))
                Capsule()
                    .fill(HermesTheme.accent)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Screen scaffolding

/// A settings-style page: warm canvas, stacked `HermesSection`s.
struct HermesScrollPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22, content: content)
                .padding(.top, 16)
                .padding(.bottom, 44)
        }
        .background(HermesTheme.groupedCanvas.ignoresSafeArea())
    }
}

extension View {
    /// Stock `Form`/`List` pages keep their controls but pick up the warm
    /// canvas, so a sub-page never flashes iOS grey against the hub. The one
    /// real definition - `SettingsView` and `PeopleView` each used to carry
    /// their own copy of these three modifiers.
    func hermesFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(HermesTheme.groupedCanvas.ignoresSafeArea())
            .tint(HermesTheme.accent)
    }
}

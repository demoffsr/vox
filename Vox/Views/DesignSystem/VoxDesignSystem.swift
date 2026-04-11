// Vox/Views/DesignSystem/VoxDesignSystem.swift
//
// Single source of truth for Vox visual language.
// The lecture translation window (TranslationStreamView) is the reference style —
// every other surface derives its look from the tokens and components below.
//
// Layering:
//   • VoxTokens  — raw design values (radius, spacing, typography, ink hierarchy)
//   • Components — GradientDivider, VoxCapsuleButton, VoxCircleIconButton, VoxCard, VoxRow
//   • LiquidGlassSurface — macOS 26 Liquid Glass wrapper with .ultraThinMaterial fallback
//   • VoxPanelChrome — shared NSVisualEffectView + NSHostingView plumbing for floating glass panels

import AppKit
import SwiftUI

// MARK: - Tokens

/// All tokens are `nonisolated` so they can be referenced from default parameter values,
/// property initializers, and non-MainActor contexts (the project uses
/// `-default-isolation=MainActor` which otherwise pins enum statics to MainActor).
nonisolated enum VoxTokens {
    enum Radius {
        /// Tab buttons, tiny inline controls.
        static let xs: CGFloat = 6
        /// Inline picker items, icon buttons, popover row cards.
        static let sm: CGFloat = 8
        /// Cinema input textfield, medium controls.
        static let md: CGFloat = 12
        /// Settings cards.
        static let lg: CGFloat = 14
        /// Floating glass panels (lecture, card, cinema, subtitles).
        static let xl: CGFloat = 16
    }

    enum Spacing {
        /// Title bar / bottom bar horizontal padding.
        static let outerH: CGFloat = 14
        /// Title bar / bottom bar vertical padding.
        static let outerV: CGFloat = 10
        /// Scroll content horizontal padding.
        static let contentH: CGFloat = 16
        /// Scroll content vertical padding.
        static let contentV: CGFloat = 14

        static let tight: CGFloat = 6
        static let compact: CGFloat = 8
        static let cozy: CGFloat = 10
    }

    enum Typo {
        static let tiny     = Font.system(size: 11, weight: .medium)
        static let small    = Font.system(size: 12, weight: .medium)
        static let body     = Font.system(size: 13, weight: .medium)
        static let bodyLg   = Font.system(size: 15)
        static let title    = Font.system(size: 15, weight: .semibold)
        static let heading  = Font.system(size: 17, weight: .bold)
        static let display  = Font.system(size: 20, weight: .bold)
        static let mono     = Font.system(size: 12, design: .monospaced)
    }

    /// White-opacity hierarchy used across all dark surfaces.
    /// Names describe *visual weight*, not opacity number — so refactors stay readable.
    enum Ink {
        static let primary    = Color.white.opacity(0.95)
        static let secondary  = Color.white.opacity(0.85)
        static let tertiary   = Color.white.opacity(0.70)
        static let muted      = Color.white.opacity(0.50)
        static let subtle     = Color.white.opacity(0.35)
        static let faint      = Color.white.opacity(0.25)
        static let whisper    = Color.white.opacity(0.12)
        static let trace      = Color.white.opacity(0.08)
        static let hairline   = Color.white.opacity(0.06)
        static let surface    = Color.white.opacity(0.04)
        static let floor      = Color.white.opacity(0.02)
    }
}

// MARK: - Shared Components

/// Horizontal gradient hairline. Fades in/out from the edges so it doesn't cut the glass hard.
/// Used as the section divider across every panel.
struct GradientDivider: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0), VoxTokens.Ink.hairline, .white.opacity(0)],
                    startPoint: axis == .horizontal ? .leading : .top,
                    endPoint:   axis == .horizontal ? .trailing : .bottom
                )
            )
            .frame(
                width:  axis == .vertical   ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

/// Capsule pill button that matches the lecture window bottom bar
/// (Clear / Copy / Customize). Accent mode switches to green for "Copied!" feedback.
struct VoxCapsuleButton: View {
    let label: String
    let icon: String?
    let isAccent: Bool
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ label: String,
        icon: String? = nil,
        isAccent: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.icon = icon
        self.isAccent = isAccent
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(VoxTokens.Typo.small)
            }
            .foregroundStyle(isAccent ? AnyShapeStyle(Color.green) : AnyShapeStyle(VoxTokens.Ink.tertiary))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isAccent ? Color.green.opacity(0.15) : VoxTokens.Ink.trace)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.easeInOut(duration: 0.2), value: isAccent)
    }
}

/// Small circular icon button (22×22 by default). Used for close buttons
/// and other icon-only controls on the lecture/card panels.
struct VoxCircleIconButton: View {
    let icon: String
    let size: CGFloat
    let action: () -> Void

    init(icon: String, size: CGFloat = 22, action: @escaping () -> Void) {
        self.icon = icon
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(VoxTokens.Ink.subtle)
                .frame(width: size, height: size)
                .background(Circle().fill(VoxTokens.Ink.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// Vertical container card for settings sections.
/// Uses Liquid Glass when available, hairline fill+border fallback otherwise.
struct VoxCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: VoxTokens.Radius.lg, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: VoxTokens.Radius.lg))
            } else {
                RoundedRectangle(cornerRadius: VoxTokens.Radius.lg, style: .continuous)
                    .fill(VoxTokens.Ink.surface)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoxTokens.Radius.lg, style: .continuous)
                .strokeBorder(VoxTokens.Ink.hairline, lineWidth: 0.5)
        )
    }
}

/// Standard settings row: icon · title · trailing control.
struct VoxRow<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let trailing: Trailing

    init(icon: String, title: String, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(VoxTokens.Ink.subtle)
                .frame(width: 16)
            Text(title)
                .font(VoxTokens.Typo.body)
                .foregroundStyle(VoxTokens.Ink.secondary)
            Spacer()
            trailing
        }
    }
}

/// Hint/help text shown below a settings row.
struct VoxHintText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(VoxTokens.Ink.faint)
            .padding(.top, 4)
            .padding(.leading, 28)
    }
}

// MARK: - Liquid Glass Surface

/// A rounded surface that uses Liquid Glass on macOS 26+ and `.ultraThinMaterial` below.
/// Prefer this over raw `.glassEffect` to keep availability handling in one place.
///
/// ```swift
/// LiquidGlassSurface(cornerRadius: VoxTokens.Radius.sm) {
///     HStack { ... }
/// }
/// ```
struct LiquidGlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    @ViewBuilder let content: Content

    init(
        cornerRadius: CGFloat = VoxTokens.Radius.md,
        tint: Color? = nil,
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            modernBody
        } else {
            fallbackBody
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private var modernBody: some View {
        switch (tint, interactive) {
        case (.some(let t), true):
            content.glassEffect(.regular.tint(t).interactive(), in: .rect(cornerRadius: cornerRadius))
        case (.some(let t), false):
            content.glassEffect(.regular.tint(t), in: .rect(cornerRadius: cornerRadius))
        case (nil, true):
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        case (nil, false):
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }

    private var fallbackBody: some View {
        content
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(VoxTokens.Ink.hairline, lineWidth: 0.5)
            )
    }
}

// MARK: - NSPanel Glass Chrome

/// Shared AppKit plumbing for floating glass panels (lecture, translation card, cinema input).
///
/// Usage from an `NSPanel` subclass:
///
/// ```swift
/// super.init(contentRect: ..., styleMask: [.nonactivatingPanel, .borderless], ...)
/// VoxPanelChrome.applyBaseConfiguration(self)
/// VoxPanelChrome.embed(myContentView, in: self)
/// ```
@MainActor
enum VoxPanelChrome {
    /// Applies the standard floating-panel configuration:
    /// floating level, transparent background, shadow, non-activating key behavior.
    /// Call this once after `super.init` from an `NSPanel` subclass.
    static func applyBaseConfiguration(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
    }

    /// Builds a rounded `.hudWindow` `NSVisualEffectView` ready to use as a panel's `contentView`.
    static func makeGlassBackground(cornerRadius: CGFloat = VoxTokens.Radius.xl) -> NSVisualEffectView {
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = cornerRadius
        visualEffect.layer?.masksToBounds = true
        return visualEffect
    }

    /// Embeds a SwiftUI view hierarchy inside a glass visual effect view and assigns it
    /// as the panel's `contentView`. Returns the `NSHostingView` so callers can compute
    /// `fittingSize` for resize-to-content behavior.
    @discardableResult
    static func embed<Content: View>(
        _ content: Content,
        in panel: NSPanel,
        cornerRadius: CGFloat = VoxTokens.Radius.xl
    ) -> NSHostingView<Content> {
        let visualEffect = makeGlassBackground(cornerRadius: cornerRadius)

        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = CGColor.clear
        hostingView.layer?.isOpaque = false

        visualEffect.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        panel.contentView = visualEffect
        return hostingView
    }
}

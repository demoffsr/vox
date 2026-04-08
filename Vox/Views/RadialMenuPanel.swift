// Vox/Views/RadialMenuPanel.swift
import AppKit
import SwiftUI

// MARK: - Radial Menu Item

struct RadialMenuItem: Identifiable {
    let id: String
    let icon: String
    let isSystemIcon: Bool
    let label: String
    let tint: Color
    let isActive: () -> Bool
    let action: () -> Void

    init(id: String, icon: String, isSystemIcon: Bool = false, label: String, tint: Color, isActive: @escaping () -> Bool, action: @escaping () -> Void) {
        self.id = id
        self.icon = icon
        self.isSystemIcon = isSystemIcon
        self.label = label
        self.tint = tint
        self.isActive = isActive
        self.action = action
    }
}

// MARK: - AppKit Panel

@MainActor
final class RadialMenuPanel: NSPanel {
    private let origin: NSPoint
    private var monitor: Any?
    var onDismiss: (() -> Void)?
    var items: [RadialMenuItem] = []

    init(origin: NSPoint) {
        self.origin = origin

        let size: CGFloat = 340
        let rect = NSRect(
            x: origin.x - size / 2,
            y: origin.y - size / 2,
            width: size,
            height: size
        )

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Hide titlebar while keeping compositing pipeline for Liquid Glass
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showAnimated() {
        let hostingView = NSHostingView(rootView: RadialMenuView(
            items: items,
            onAction: { [weak self] in
                self?.dismissAnimated()
            }
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = CGColor.clear

        contentView = hostingView

        alphaValue = 1
        orderFrontRegardless()

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissAnimated()
        }
    }

    func dismissAnimated() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        NotificationCenter.default.post(name: .radialMenuDismiss, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.orderOut(nil)
            self?.onDismiss?()
        }
    }

    override func close() {
        dismissAnimated()
    }
}

extension Notification.Name {
    static let radialMenuDismiss = Notification.Name("radialMenuDismiss")
}

// MARK: - SwiftUI Radial Menu View

struct RadialMenuView: View {
    let items: [RadialMenuItem]
    let onAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowing = false
    @State private var isDismissing = false
    @State private var hoveredItem: String?

    // Evenly spaced around circle — triangle (3), diamond (4), etc.
    private func offset(for index: Int, count: Int) -> CGSize {
        let radius: CGFloat = 68
        let startAngle: CGFloat = 90
        let step: CGFloat = 360 / CGFloat(count)
        let angleDeg = startAngle - step * CGFloat(index)
        let angleRad = angleDeg * .pi / 180

        return CGSize(
            width: cos(angleRad) * radius,
            height: sin(angleRad) * radius
        )
    }

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                radialButton(item: item, index: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            onAction()
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isShowing = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuDismiss)) { _ in
            withAnimation(.easeIn(duration: 0.15)) {
                isDismissing = true
            }
        }
    }

    private func radialButton(item: RadialMenuItem, index: Int) -> some View {
        let isHovered = hoveredItem == item.id
        let itemOffset = offset(for: index, count: items.count)
        let isActive = item.isActive()

        return Button(action: {
            item.action()
            onAction()
        }) {
            VStack(spacing: 5) {
                ZStack {
                    Group {
                        if item.isSystemIcon {
                            Image(systemName: item.icon)
                                .font(.system(size: 20, weight: .medium))
                        } else {
                            Image(item.icon)
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                        }
                    }
                    .foregroundStyle(isActive ? item.tint : .primary)
                }
                .frame(width: 52, height: 52)
                .glassEffect(
                    isActive ? .regular.tint(item.tint).interactive() : .regular.interactive(),
                    in: .circle
                )
                .overlay {
                    if colorScheme == .light {
                        Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                    }
                }

                Text(item.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                    .overlay {
                        if colorScheme == .light {
                            Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
                        }
                    }
            }
            .scaleEffect(isHovered ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredItem = hovered ? item.id : nil
            }
        }
        .offset(isShowing && !isDismissing ? itemOffset : .zero)
        .scaleEffect(isShowing && !isDismissing ? 1 : 0)
        .opacity(isShowing && !isDismissing ? 1 : 0)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.7)
                .delay(Double(index) * 0.05),
            value: isShowing
        )
        .animation(.easeIn(duration: 0.15), value: isDismissing)
    }
}

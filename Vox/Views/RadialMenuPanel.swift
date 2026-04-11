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
        var rect = NSRect(
            x: origin.x - size / 2,
            y: origin.y - size / 2,
            width: size,
            height: size
        )

        // Clamp to the screen containing the cursor so glass doesn't span monitors
        let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            rect.origin.x = min(max(rect.origin.x, visibleFrame.minX), visibleFrame.maxX - size)
            rect.origin.y = min(max(rect.origin.y, visibleFrame.minY), visibleFrame.maxY - size)
        }

        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

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
        contentView = hostingView

        alphaValue = 0
        orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.alphaValue = 1
            NotificationCenter.default.post(name: .radialMenuReady, object: nil)
        }

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
    static let radialMenuReady = Notification.Name("radialMenuReady")
}

// MARK: - SwiftUI Radial Menu View

struct RadialMenuView: View {
    let items: [RadialMenuItem]
    let onAction: () -> Void

    @State private var isShowing = false
    @State private var isDismissing = false
    @State private var hoveredItem: String?

    // Evenly spaced around circle
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
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuReady)) { _ in
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
            VStack(spacing: 4) {
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
                .background(.thinMaterial, in: .circle)
                .overlay {
                    if isActive {
                        Circle().fill(item.tint.opacity(0.15))
                    }
                }

                Text(item.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .drawingGroup()
            }
            .scaleEffect(isHovered ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.15)) {
                hoveredItem = hovered ? item.id : nil
            }
        }
        .offset(itemOffset)
        .scaleEffect(isShowing && !isDismissing ? 1 : 0.01)
        .opacity(isShowing && !isDismissing ? 1 : 0)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.7)
                .delay(Double(index) * 0.05),
            value: isShowing
        )
        .animation(.easeIn(duration: 0.15), value: isDismissing)
    }
}

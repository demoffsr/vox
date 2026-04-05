import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    init(contentView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        self.contentView = NSHostingView(rootView: contentView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(at position: CGPoint) {
        if let hostingView = contentView {
            let fittingSize = hostingView.fittingSize
            setContentSize(fittingSize)
        }
        let origin = NSPoint(
            x: position.x + 10,
            y: position.y - frame.height - 10
        )
        setFrameOrigin(adjustedOrigin(origin))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    private func adjustedOrigin(_ origin: NSPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return origin }
        let screenFrame = screen.visibleFrame
        var adjusted = origin

        if adjusted.x + frame.width > screenFrame.maxX {
            adjusted.x = screenFrame.maxX - frame.width - 10
        }
        if adjusted.x < screenFrame.minX {
            adjusted.x = screenFrame.minX + 10
        }
        if adjusted.y < screenFrame.minY {
            adjusted.y = screenFrame.minY + 10
        }
        if adjusted.y + frame.height > screenFrame.maxY {
            adjusted.y = screenFrame.maxY - frame.height - 10
        }
        return adjusted
    }
}

@MainActor
final class PanelController {
    private var panel: FloatingPanel?
    private let viewModel: TranslationViewModel

    init(viewModel: TranslationViewModel) {
        self.viewModel = viewModel
    }

    func showPanel() {
        if panel == nil {
            let cardView = TranslationCardView(viewModel: viewModel)
            panel = FloatingPanel(contentView: cardView)
        }
        panel?.show(at: viewModel.panelPosition)
    }

    func hidePanel() {
        panel?.dismiss()
    }

    func updateVisibility() {
        if viewModel.isPanelVisible {
            showPanel()
        } else {
            hidePanel()
        }
    }
}

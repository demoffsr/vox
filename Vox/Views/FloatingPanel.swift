import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var clickOutsideMonitor: Any?
    var onClickOutside: (() -> Void)?

    init(contentView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        // Wrap in AnyView for type erasure
        let hosting = NSHostingView(rootView: AnyView(contentView))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear

        // Make the hosting view's background fully transparent
        if let layer = hosting.layer {
            layer.isOpaque = false
        }

        self.contentView = hosting
        self.hostingView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(at position: CGPoint) {
        // Size to fit content
        if let hosting = hostingView {
            let size = hosting.fittingSize
            setContentSize(size)
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

        // Monitor clicks outside the panel
        startClickOutsideMonitor()
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return }
            // Check if click is outside our frame
            let clickLocation = NSEvent.mouseLocation
            if !self.frame.contains(clickLocation) {
                DispatchQueue.main.async {
                    self.onClickOutside?()
                }
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// Resize panel to match current content size
    func resizeToFit() {
        guard let hosting = hostingView else { return }
        let newSize = hosting.fittingSize
        let currentFrame = frame
        // Keep top-left corner pinned (grow downward in screen coords = shrink y origin)
        let newOrigin = NSPoint(
            x: currentFrame.origin.x,
            y: currentFrame.maxY - newSize.height
        )
        setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: true)
    }

    func dismiss() {
        stopClickOutsideMonitor()
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
    private var resizeTimer: Timer?

    init(viewModel: TranslationViewModel) {
        self.viewModel = viewModel
    }

    func showPanel() {
        let cardView = TranslationCardView(viewModel: viewModel)
        panel = FloatingPanel(contentView: cardView)
        panel?.onClickOutside = { [weak self] in
            self?.viewModel.dismissPanel()
        }
        panel?.show(at: viewModel.panelPosition)

        // Start polling for size changes while translating
        startResizePolling()
    }

    func hidePanel() {
        stopResizePolling()
        panel?.dismiss()
    }

    func updateVisibility() {
        if viewModel.isPanelVisible {
            showPanel()
        } else {
            hidePanel()
        }
    }

    private func startResizePolling() {
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.panel?.resizeToFit()
                // Stop polling when translation is done
                if self?.viewModel.isTranslating == false {
                    self?.stopResizePolling()
                    // One final resize
                    self?.panel?.resizeToFit()
                }
            }
        }
    }

    private func stopResizePolling() {
        resizeTimer?.invalidate()
        resizeTimer = nil
    }
}

// Vox/Views/TranslationStreamPanel.swift
import AppKit
import SwiftUI

@MainActor
final class TranslationStreamPanel: NSPanel {
    private let viewModel: TranslationStreamViewModel
    var onClose: (() -> Void)?

    init(viewModel: TranslationStreamViewModel) {
        self.viewModel = viewModel

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled, .resizable, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "Vox Translation"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        minSize = NSSize(width: 400, height: 200)
        isReleasedWhenClosed = false

        let streamView = TranslationStreamView(
            viewModel: viewModel,
            onLanguageChanged: { [weak self] lang in
                self?.onLanguageChanged(lang)
            },
            onClose: { [weak self] in
                self?.dismiss()
            }
        )
        let hostingView = NSHostingView(rootView: streamView)
        self.contentView = hostingView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showCentered() {
        center()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onClose?()
        })
    }

    // Called by NSPanel when user clicks the close button
    override func close() {
        dismiss()
    }

    private func onLanguageChanged(_ lang: TargetLanguage) {
        AppSettings.shared.subtitleTranslationLanguage = lang
    }
}

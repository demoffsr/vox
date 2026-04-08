// Vox/Views/TranslationStreamPanel.swift
import AppKit
import SwiftUI

@MainActor
final class TranslationStreamPanel: NSPanel {
    private let viewModel: TranslationStreamViewModel
    var onClose: (() -> Void)?
    var onCustomize: ((ProcessingMode) -> Void)?

    init(viewModel: TranslationStreamViewModel) {
        self.viewModel = viewModel

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        minSize = NSSize(width: 400, height: 200)
        isReleasedWhenClosed = false

        // Glass background (like Spotlight)
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true

        let streamView = TranslationStreamView(
            viewModel: viewModel,
            onLanguageChanged: { [weak self] lang in
                self?.onLanguageChanged(lang)
            },
            onCustomize: { [weak self] mode in
                self?.onCustomize?(mode)
            },
            onClose: { [weak self] in
                self?.dismiss()
            }
        )
        let hostingView = NSHostingView(rootView: streamView)
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

        self.contentView = visualEffect
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

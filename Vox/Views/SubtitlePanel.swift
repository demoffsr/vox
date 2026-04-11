import AppKit

// MARK: - Subtitle Panel (Pure AppKit)

/// Floating subtitle overlay. Pure AppKit — no SwiftUI, no observation issues.
/// Dual-line display: original (small, dim) on top, translation (large, bright) below.
/// Supports streaming — call appendTranslation() per token for typewriter effect.
@MainActor
final class SubtitlePanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let originalLabel = NSTextField(labelWithString: "")
    private var fadeTimer: Timer?
    private var isFadingOut = false

    private var rawText: String = ""

    /// When set, panel displays this instead of original transcriber text.
    var translationOverride: String?

    /// Generation counter — prevents stale streaming tokens from updating the panel.
    private var translationGeneration: UInt64 = 0

    private let maxLineWidth: CGFloat = 550
    private let subtitleFont = NSFont.systemFont(ofSize: 20, weight: .medium)
    private let originalFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private static let panelWidth: CGFloat = 620

    /// What's currently shown on screen (translation if available, otherwise original).
    var displayText: String {
        translationOverride ?? rawText
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        VoxPanelChrome.applyBaseConfiguration(self)
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        alphaValue = 0

        // Two-layer background:
        //   1) .hudWindow NSVisualEffectView — same glass base as lecture/card panels
        //   2) dark overlay — keeps text readable on bright video frames
        //
        // Pure glass alone disappears on white/yellow scenes, so we retain a 0.55 black
        // wash under the labels while gaining the glass edge of the rest of the app.
        let visualEffect = VoxPanelChrome.makeGlassBackground(cornerRadius: 16)
        visualEffect.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100)

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor

        // Original label — small, dim, shown above translation
        originalLabel.font = originalFont
        originalLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        originalLabel.backgroundColor = .clear
        originalLabel.isBezeled = false
        originalLabel.isEditable = false
        originalLabel.isSelectable = false
        originalLabel.lineBreakMode = .byTruncatingTail
        originalLabel.maximumNumberOfLines = 1
        originalLabel.alignment = .center
        originalLabel.cell?.wraps = false
        originalLabel.cell?.isScrollable = false
        originalLabel.isHidden = true

        // Translation/main label
        label.font = subtitleFont
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.alignment = .center
        label.cell?.wraps = true
        label.cell?.isScrollable = false

        let textShadow = NSShadow()
        textShadow.shadowBlurRadius = 4
        textShadow.shadowOffset = NSSize(width: 0, height: -1)
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        label.shadow = textShadow

        bg.addSubview(originalLabel)
        bg.addSubview(label)
        visualEffect.addSubview(bg)
        self.contentView = visualEffect

        // Layout: visualEffect resizes with panel, bg pinned to its edges, labels pinned to bg.
        visualEffect.autoresizingMask = [.width, .height]
        bg.translatesAutoresizingMaskIntoConstraints = false
        originalLabel.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            bg.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            bg.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),

            originalLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 24),
            originalLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -24),
            originalLabel.topAnchor.constraint(equalTo: bg.topAnchor, constant: 10),

            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: originalLabel.bottomAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
        ])

        positionAtBottom()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Public API

    func showVolatile(_ text: String) {
        if translationOverride == nil {
            rawText = text
            updateLabel()
        }
        show()
    }

    func showFinal(_ text: String) {
        if translationOverride == nil {
            rawText = rawText.isEmpty ? text : rawText + " " + text
            let words = rawText.split(separator: " ")
            if words.count > 60 {
                rawText = words.suffix(30).joined(separator: " ")
            }
            updateLabel()
        }
        show()
    }

    /// Set translation text directly (no streaming). Updates label immediately.
    func showTranslation(_ text: String) {
        translationOverride = text
        updateLabel()
        show()
    }

    /// Append a streaming token to the translation. Typewriter effect.
    /// Checks generation to ignore tokens from cancelled requests.
    func appendTranslation(_ token: String, generation: UInt64) {
        guard generation == translationGeneration else { return }
        if translationOverride == nil || translationOverride == "..." {
            translationOverride = ""
        }
        translationOverride! += token
        updateLabel()
        show()
    }

    /// Clears translation and returns a new generation token.
    @discardableResult
    func clearTranslation() -> UInt64 {
        translationGeneration += 1
        translationOverride = nil
        originalLabel.isHidden = true
        originalLabel.stringValue = ""
        updateLabel()
        return translationGeneration
    }

    /// Show "..." placeholder while waiting for first translation token.
    func showTranslationPending() {
        translationOverride = "..."
        updateLabel()
        show()
    }

    func fadeOut() {
        guard !isFadingOut else { return }
        isFadingOut = true
        fadeTimer?.invalidate()
        fadeTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isFadingOut else { return }
            self.isFadingOut = false
            self.orderOut(nil)
            self.rawText = ""
            self.translationOverride = nil
            self.label.stringValue = ""
            self.originalLabel.stringValue = ""
            self.originalLabel.isHidden = true
        })
    }

    // MARK: - Private

    private func updateLabel() {
        let text = translationOverride ?? rawText
        let allWords = text.split(separator: " ").map(String.init)

        let maxLines = 2

        // Word-wrap by measured pixel width
        var lines: [String] = []
        var currentLine = ""
        for word in allWords {
            let candidate = currentLine.isEmpty ? word : currentLine + " " + word
            if measure(candidate) > maxLineWidth && !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = word
            } else {
                currentLine = candidate
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        let visible = lines.suffix(maxLines)
        label.stringValue = visible.joined(separator: "\n")
        label.maximumNumberOfLines = maxLines
    }

    private func show() {
        isFadingOut = false
        fadeTimer?.invalidate()
        alphaValue = 1
        if !isVisible {
            positionAtBottom()
        }
        orderFrontRegardless()

        fadeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.fadeOut() }
        }
    }

    private func positionAtBottom() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: screenFrame.midX - Self.panelWidth / 2,
            y: screenFrame.minY + 80
        ))
    }

    private func measure(_ text: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: subtitleFont]
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }
}

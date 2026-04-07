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

    private var confirmedWords: [String] = []
    private var volatileText: String = ""

    /// When set, panel displays this instead of original transcriber text.
    /// Original state (confirmedWords/volatileText) keeps accumulating in background.
    var translationOverride: String?

    /// Generation counter — prevents stale streaming tokens from updating the panel.
    private var translationGeneration: UInt64 = 0

    private let maxLineWidth: CGFloat = 550
    private let subtitleFont = NSFont.systemFont(ofSize: 20, weight: .medium)
    private let originalFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private static let panelWidth: CGFloat = 620

    /// Original (untranslated) text from transcriber — used as translation input.
    var originalDisplayText: String {
        var all = confirmedWords.joined(separator: " ")
        if !volatileText.isEmpty {
            if !all.isEmpty { all += " " }
            all += volatileText
        }
        return all
    }

    /// What's currently shown on screen (translation if available, otherwise original).
    var displayText: String {
        translationOverride ?? originalDisplayText
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        alphaValue = 0

        // Dark rounded background
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 100))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        bg.layer?.cornerRadius = 10

        // Original label — small, dim, shown above translation
        originalLabel.font = originalFont
        originalLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        originalLabel.backgroundColor = .clear
        originalLabel.isBezeled = false
        originalLabel.isEditable = false
        originalLabel.isSelectable = false
        originalLabel.lineBreakMode = .byTruncatingTail
        originalLabel.maximumNumberOfLines = 1
        originalLabel.alignment = .left
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
        label.alignment = .left
        label.cell?.wraps = true
        label.cell?.isScrollable = false

        bg.addSubview(originalLabel)
        bg.addSubview(label)
        self.contentView = bg

        // Layout
        bg.autoresizingMask = [.width, .height]
        originalLabel.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
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
        volatileText = text
        // When translation is active, don't overwrite the label with English
        if translationOverride == nil {
            updateLabel()
        }
        show()
    }

    func showFinal(_ text: String) {
        confirmedWords += text.split(separator: " ").map(String.init)
        volatileText = ""
        // When translation is active, don't overwrite the label with English
        if translationOverride == nil {
            updateLabel()
        }
        show()
        // Trim old words
        if confirmedWords.count > 60 {
            confirmedWords = Array(confirmedWords.suffix(30))
        }
    }

    /// Accumulate final words without showing the panel. Used when translation stream is active.
    func accumulateFinal(_ text: String) {
        confirmedWords += text.split(separator: " ").map(String.init)
        volatileText = ""
        if confirmedWords.count > 60 {
            confirmedWords = Array(confirmedWords.suffix(30))
        }
    }

    /// Accumulate volatile text without showing the panel. Used when translation stream is active.
    func accumulateVolatile(_ text: String) {
        volatileText = text
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
            self.confirmedWords.removeAll()
            self.volatileText = ""
            self.translationOverride = nil
            self.label.stringValue = ""
            self.originalLabel.stringValue = ""
            self.originalLabel.isHidden = true
        })
    }

    // MARK: - Private

    private func updateLabel() {
        let text = translationOverride ?? originalDisplayText
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

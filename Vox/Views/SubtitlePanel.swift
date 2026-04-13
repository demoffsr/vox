import AppKit

// MARK: - Subtitle Panel (Pure AppKit)

/// Floating subtitle overlay. Pure AppKit — no SwiftUI, no observation issues.
/// Supports streaming — call appendTranslation() per token for typewriter effect.
///
/// The panel is visible continuously while subtitles are enabled (no auto-fade timer);
/// its height is recalculated on every text update so the box hugs current content
/// (1 line ≈ topPadding + lineHeight + bottomPadding, 2 lines adds one more lineHeight).
/// The bottom edge stays pinned to the screen so text doesn't jump as lines grow.
@MainActor
final class SubtitlePanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var isFadingOut = false

    private var rawText: String = ""

    /// When set, panel displays this instead of original transcriber text.
    var translationOverride: String?

    /// Generation counter — prevents stale streaming tokens from updating the panel.
    private var translationGeneration: UInt64 = 0

    private let maxLineWidth: CGFloat = 550
    private let subtitleFont = NSFont.systemFont(ofSize: 20, weight: .medium)
    private static let panelWidth: CGFloat = 620
    private static let verticalPadding: CGFloat = 12
    private static let maxLines = 2

    /// Actual line height NSTextField uses for the subtitle font — computed via
    /// NSLayoutManager so our frame math matches what AppKit will actually draw.
    private lazy var subtitleLineHeight: CGFloat = {
        let lm = NSLayoutManager()
        return ceil(lm.defaultLineHeight(for: subtitleFont))
    }()

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
        // wash under the label while gaining the glass edge of the rest of the app.
        let visualEffect = VoxPanelChrome.makeGlassBackground(cornerRadius: 16)

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor

        // Subtitle label — centered, multi-line, clipped to maxLines.
        label.font = subtitleFont
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = Self.maxLines
        label.alignment = .center
        label.cell?.wraps = true
        label.cell?.isScrollable = false

        let textShadow = NSShadow()
        textShadow.shadowBlurRadius = 4
        textShadow.shadowOffset = NSSize(width: 0, height: -1)
        textShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        label.shadow = textShadow

        bg.addSubview(label)
        visualEffect.addSubview(bg)
        self.contentView = visualEffect

        // Layout: visualEffect resizes with panel, bg pinned to its edges, label pinned
        // to bg with symmetric vertical padding. No center constraint — the frame math
        // in fit(toLineCount:) guarantees bg height == padding*2 + label intrinsic height.
        visualEffect.autoresizingMask = [.width, .height]
        bg.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            bg.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            bg.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),

            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: Self.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -Self.verticalPadding),
        ])

        // Seed frame to 1-line height + correct screen position. Height is recomputed
        // on every updateLabel() call via fit(toLineCount:).
        fit(toLineCount: 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Public API

    /// Make the panel visible and ready to stream subtitles. Called from
    /// `SubtitleService.start()` so the overlay shows up immediately, before the
    /// first transcribed word.
    func activate() {
        isFadingOut = false
        updateLabel() // size panel to current (possibly empty) content
        alphaValue = 1
        orderFrontRegardless()
    }

    func showVolatile(_ text: String) {
        if translationOverride == nil {
            rawText = text
            updateLabel()
        }
        makeVisible()
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
        makeVisible()
    }

    /// Set translation text directly (no streaming). Updates label immediately.
    func showTranslation(_ text: String) {
        translationOverride = text
        updateLabel()
        makeVisible()
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
        makeVisible()
    }

    /// Clears translation and returns a new generation token.
    @discardableResult
    func clearTranslation() -> UInt64 {
        translationGeneration += 1
        translationOverride = nil
        updateLabel()
        return translationGeneration
    }

    /// Show "..." placeholder while waiting for first translation token.
    func showTranslationPending() {
        translationOverride = "..."
        updateLabel()
        makeVisible()
    }

    /// Fade out and hide the panel. Called from `SubtitleService.stop()` — the panel
    /// never hides on its own while subtitles are running.
    func fadeOut() {
        guard !isFadingOut else { return }
        isFadingOut = true
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
        })
    }

    // MARK: - Private

    private func updateLabel() {
        let text = translationOverride ?? rawText
        let allWords = text.split(separator: " ").map(String.init)

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

        let visible = lines.suffix(Self.maxLines)
        label.stringValue = visible.joined(separator: "\n")
        label.maximumNumberOfLines = Self.maxLines

        // Panel hugs current line count (minimum 1 so empty state stays visible).
        let lineCount = max(1, visible.count)
        fit(toLineCount: lineCount)
    }

    private func makeVisible() {
        isFadingOut = false
        alphaValue = 1
        orderFrontRegardless()
    }

    /// Resizes the panel height to `verticalPadding*2 + lineCount * lineHeight`,
    /// keeping the bottom edge pinned so text doesn't jump when the line count changes.
    private func fit(toLineCount lineCount: Int) {
        let totalHeight = Self.verticalPadding * 2 + CGFloat(lineCount) * subtitleLineHeight

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let newFrame = NSRect(
            x: screenFrame.midX - Self.panelWidth / 2,
            y: screenFrame.minY + 80,
            width: Self.panelWidth,
            height: totalHeight
        )
        setFrame(newFrame, display: true)
    }

    private func measure(_ text: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: subtitleFont]
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }
}

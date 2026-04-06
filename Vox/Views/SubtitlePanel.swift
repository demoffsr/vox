import AppKit

// MARK: - Subtitle Panel (Pure AppKit)

/// Floating subtitle overlay. Pure AppKit — no SwiftUI, no observation issues.
/// Pixel-measured line breaking, YouTube-style 2-line display.
@MainActor
final class SubtitlePanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private var fadeTimer: Timer?
    private var isFadingOut = false

    private var confirmedWords: [String] = []
    private var volatileText: String = ""

    private let maxLineWidth: CGFloat = 450
    private let subtitleFont = NSFont.systemFont(ofSize: 20, weight: .medium)
    private static let panelWidth: CGFloat = 520

    /// Combined display text (for IPC).
    var displayText: String {
        var all = confirmedWords.joined(separator: " ")
        if !volatileText.isEmpty {
            if !all.isEmpty { all += " " }
            all += volatileText
        }
        return all
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

        // Label setup
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

        bg.addSubview(label)
        self.contentView = bg

        // Layout
        bg.autoresizingMask = [.width, .height]
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -12),
        ])

        positionAtBottom()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Public API

    func showVolatile(_ text: String) {
        volatileText = text
        updateLabel()
        show()
    }

    func showFinal(_ text: String) {
        confirmedWords += text.split(separator: " ").map(String.init)
        volatileText = ""
        updateLabel()
        show()
        // Trim old words
        if confirmedWords.count > 60 {
            confirmedWords = Array(confirmedWords.suffix(30))
        }
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
            self.label.stringValue = ""
        })
    }

    // MARK: - Private

    private func updateLabel() {
        // Combine all words
        var allWords = confirmedWords
        if !volatileText.isEmpty {
            allWords += volatileText.split(separator: " ").map(String.init)
        }

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

        // Show last 2 lines
        let visible = lines.suffix(2)
        label.stringValue = visible.joined(separator: "\n")
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

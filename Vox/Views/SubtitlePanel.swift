import AppKit
import SwiftUI

/// Observable model for subtitle text — enables lightweight in-place updates.
@Observable
@MainActor
final class SubtitleTextModel {
    var finalizedText: String = ""
    var volatileText: String = ""
    var isVisible: Bool = false

    /// The display string: finalized lines + current volatile words.
    var displayText: String {
        let combined: String
        if finalizedText.isEmpty {
            combined = volatileText
        } else if volatileText.isEmpty {
            combined = finalizedText
        } else {
            combined = finalizedText + " " + volatileText
        }
        // Keep last ~20 words for readability
        let words = combined.split(separator: " ")
        if words.count > 20 {
            return words.suffix(20).joined(separator: " ")
        }
        return combined
    }

    func appendFinal(_ text: String) {
        if finalizedText.isEmpty {
            finalizedText = text
        } else {
            finalizedText += " " + text
        }
        volatileText = ""
        // Trim finalized text to prevent unbounded growth (keep last ~40 words)
        let words = finalizedText.split(separator: " ")
        if words.count > 40 {
            finalizedText = words.suffix(40).joined(separator: " ")
        }
    }

    func updateVolatile(_ text: String) {
        volatileText = text
    }

    func clear() {
        finalizedText = ""
        volatileText = ""
    }
}

/// Floating subtitle overlay at the bottom of the screen.
/// Visible over any application, including fullscreen apps.
@MainActor
final class SubtitlePanel: NSPanel {
    let textModel = SubtitleTextModel()
    private var fadeTimer: Timer?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
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

        // Single hosting view that observes the model — never recreated
        let view = SubtitleContentView(model: textModel)
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        self.contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Update with volatile (partial) text — word-by-word as speech is recognized.
    func showVolatile(_ text: String) {
        textModel.updateVolatile(text)
        ensureVisible()
        resetFadeTimer()
    }

    /// Update with finalized text — confirmed, won't change.
    func showFinal(_ text: String) {
        textModel.appendFinal(text)
        ensureVisible()
        resetFadeTimer()
    }

    /// Hide subtitles.
    func fadeOut() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        textModel.isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.textModel.clear()
        })
    }

    private func ensureVisible() {
        textModel.isVisible = true
        if !isVisible {
            positionAtBottom()
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            animator().alphaValue = 1
        }
        // Reposition as text grows/shrinks
        positionAtBottom()
    }

    private func resetFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.fadeOut()
            }
        }
    }

    private func positionAtBottom() {
        guard let screen = NSScreen.main, let hosting = contentView as? NSHostingView<SubtitleContentView> else { return }
        let size = hosting.fittingSize
        let clamped = NSSize(width: min(size.width, 800), height: max(size.height, 40))
        setContentSize(clamped)
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - clamped.width / 2
        let y = screenFrame.minY + 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Subtitle Content View

private struct SubtitleContentView: View {
    @State var model: SubtitleTextModel

    var body: some View {
        let text = model.displayText
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.75))
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 760)
                .animation(.easeOut(duration: 0.08), value: text)
        }
    }
}

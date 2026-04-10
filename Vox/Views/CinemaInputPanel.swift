import AppKit
import SwiftUI

// MARK: - AppKit Panel

@MainActor
final class CinemaInputPanel: NSPanel {
    private let origin: NSPoint
    var onSubmit: ((String) -> Void)?
    var onSkip: (() -> Void)?

    init(origin: NSPoint) {
        self.origin = origin

        let width: CGFloat = 280
        let height: CGFloat = 100
        var rect = NSRect(
            x: origin.x - width / 2,
            y: origin.y - height / 2,
            width: width,
            height: height
        )

        // Clamp to the screen containing the cursor
        let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            rect.origin.x = min(max(rect.origin.x, visibleFrame.minX), visibleFrame.maxX - width)
            rect.origin.y = min(max(rect.origin.y, visibleFrame.minY), visibleFrame.maxY - height)
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
        let hostingView = NSHostingView(rootView: CinemaInputView(
            onSubmit: { [weak self] showName in
                self?.dismissAnimated()
                self?.onSubmit?(showName)
            },
            onSkip: { [weak self] in
                self?.dismissAnimated()
                self?.onSkip?()
            }
        ))
        contentView = hostingView

        alphaValue = 0
        orderFrontRegardless()

        // Try to get keyboard focus without stealing key window from fullscreen player
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.alphaValue = 1
            // makeKey needed for text field input in NSPanel
            self.makeKey()
        }

        // NOTE: no global click monitor here — it used to auto-dismiss on any click
        // anywhere, which silently ate the show name if the user clicked the video
        // player before hitting Enter. Dismissal happens via Enter (onSubmit),
        // Skip button, or Esc (cancelOperation).
    }

    func dismissAnimated() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    override func close() {
        dismissAnimated()
        onSkip?()
    }

    override func cancelOperation(_ sender: Any?) {
        dismissAnimated()
        onSkip?()
    }
}

// MARK: - SwiftUI View

struct CinemaInputView: View {
    let onSubmit: (String) -> Void
    let onSkip: () -> Void

    @State private var showName = ""
    @State private var isShowing = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            TextField("What are you watching?", text: $showName)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .focused($isFocused)
                .onSubmit {
                    let trimmed = showName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        onSubmit(trimmed)
                    }
                }
                .onExitCommand { onSkip() }

            Button(action: onSkip) {
                Text("Skip")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .scaleEffect(isShowing ? 1 : 0.5)
        .opacity(isShowing ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isShowing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFocused = true
            }
        }
    }
}

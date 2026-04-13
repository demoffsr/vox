import SwiftUI
import Carbon.HIToolbox

@Observable
@MainActor
final class AppCoordinator {
    let viewModel = TranslationViewModel()
    private var panelController: PanelController?
    private var hotkeyService: HotkeyService?
    private var radialMenuPanel: RadialMenuPanel?
    private var cinemaInputPanel: CinemaInputPanel?

    // Set by AppDelegate after init
    weak var subtitleService: SubtitleService?

    init() {
        panelController = PanelController(viewModel: viewModel)

        hotkeyService = HotkeyService()
        hotkeyService?.start()

        // Cmd+T → if text selected: translate; otherwise: radial menu
        hotkeyService?.register(keyCode: kVK_ANSI_T, modifiers: cmdKey) { [weak self] in
            Task { @MainActor in
                self?.smartHotkey()
            }
        }

        viewModel.onPanelVisibilityChanged = { [weak self] in
            self?.panelController?.updateVisibility()
        }
    }

    func translate() {
        viewModel.translateFromClipboard()
    }

    func showLastOrTranslate() {
        if viewModel.hasLastResult {
            viewModel.showLastResult()
        } else {
            viewModel.translateFromClipboard()
        }
    }

    func translateText(_ text: String) {
        viewModel.translateDirectly(text: text)
    }

    /// Cmd+T: selected text → translate, no selection → radial menu
    private func smartHotkey() {
        let oldCount = NSPasteboard.general.changeCount
        let clipboard = ClipboardService()
        clipboard.simulateCopy()

        Task {
            try? await Task.sleep(for: .milliseconds(150))
            let newText = NSPasteboard.general.string(forType: .string) ?? ""
            let newCount = NSPasteboard.general.changeCount

            // changeCount bump = system actually copied something (text was selected)
            if newCount != oldCount && !newText.isEmpty {
                translate()
            } else {
                toggleRadialMenu()
            }
        }
    }

    func toggleCinemaMode() {
        guard let service = subtitleService else { return }
        let isCinemaActive = AppSettings.shared.subtitleTranslationLanguage != nil
            && AppSettings.shared.subtitleDisplayMode == .cinema

        if isCinemaActive {
            if service.isRunning {
                service.switchTranslationMode(to: nil)
            } else {
                AppSettings.shared.subtitleTranslationLanguage = nil
            }
            AppSettings.shared.subtitleDisplayMode = .lecture
        } else {
            let lang: TargetLanguage = AppSettings.shared.subtitleTranslationLanguage ?? .russian
            AppSettings.shared.subtitleDisplayMode = .cinema

            if service.isRunning {
                service.switchDisplayMode(to: .cinema)
                if AppSettings.shared.subtitleTranslationLanguage == nil {
                    service.switchTranslationMode(to: lang)
                }
            } else {
                AppSettings.shared.subtitleTranslationLanguage = lang
                Task {
                    service.subtitleLocale = AppSettings.shared.subtitleLanguage.locale
                    await service.start()
                }
            }
        }
    }

    // MARK: - Radial Menu

    func toggleRadialMenu() {
        if let panel = radialMenuPanel, panel.isVisible {
            dismissRadialMenu()
            return
        }
        showRadialMenu()
    }

    private func showRadialMenu() {
        dismissRadialMenu()

        let mouseLocation = NSEvent.mouseLocation
        let panel = RadialMenuPanel(origin: mouseLocation)

        panel.items = buildRadialItems()
        panel.onDismiss = { [weak self] in
            self?.radialMenuPanel = nil
        }

        radialMenuPanel = panel
        panel.showAnimated()
    }

    func dismissRadialMenu() {
        radialMenuPanel?.dismissAnimated()
        radialMenuPanel = nil
    }

    private func buildRadialItems() -> [RadialMenuItem] {
        [
            RadialMenuItem(
                id: "translate",
                icon: "RadialTranslate",
                label: "Look Up",
                tint: .purple,
                isActive: { false },
                action: { [weak self] in self?.translate() }
            ),
            RadialMenuItem(
                id: "subtitles",
                icon: "RadialSubtitles",
                label: "Transcribe",
                tint: .green,
                isActive: { [weak self] in
                    guard let service = self?.subtitleService else { return false }
                    // Active only when subtitles run WITHOUT translation
                    return service.isRunning && AppSettings.shared.subtitleTranslationLanguage == nil
                },
                action: { [weak self] in
                    guard let service = self?.subtitleService else { return }
                    Task {
                        if service.isRunning {
                            await service.stop()
                        } else {
                            service.subtitleLocale = AppSettings.shared.subtitleLanguage.locale
                            await service.start()
                        }
                    }
                }
            ),
            RadialMenuItem(
                id: "translation",
                icon: "RadialTranslation",
                label: "Study Mode",
                tint: .blue,
                isActive: {
                    AppSettings.shared.subtitleTranslationLanguage != nil
                        && AppSettings.shared.subtitleDisplayMode == .lecture
                },
                action: { [weak self] in
                    guard let service = self?.subtitleService else { return }
                    let hasTranslation = AppSettings.shared.subtitleTranslationLanguage != nil
                    if hasTranslation {
                        if service.isRunning {
                            service.switchTranslationMode(to: nil)
                        } else {
                            AppSettings.shared.subtitleTranslationLanguage = nil
                        }
                    } else {
                        AppSettings.shared.subtitleDisplayMode = .lecture
                        let lang: TargetLanguage = .russian
                        if service.isRunning {
                            service.switchTranslationMode(to: lang)
                        } else {
                            AppSettings.shared.subtitleTranslationLanguage = lang
                            Task {
                                service.subtitleLocale = AppSettings.shared.subtitleLanguage.locale
                                await service.start()
                            }
                        }
                    }
                }
            ),
            RadialMenuItem(
                id: "cinema",
                icon: "RadialCinema",
                label: "TV Mode",
                tint: .orange,
                isActive: {
                    AppSettings.shared.subtitleTranslationLanguage != nil
                        && AppSettings.shared.subtitleDisplayMode == .cinema
                },
                action: { [weak self] in self?.handleCinemaButton() }
            ),
        ]
    }

    // MARK: - Cinema Input

    private func handleCinemaButton() {
        let isCinemaActive = AppSettings.shared.subtitleTranslationLanguage != nil
            && AppSettings.shared.subtitleDisplayMode == .cinema
        if isCinemaActive {
            toggleCinemaMode()
        } else {
            showCinemaInput()
        }
    }

    private func showCinemaInput() {
        let mouseLocation = NSEvent.mouseLocation
        // Radial menu is already dismissing (onAction was called).
        // Show input panel at the same position after dismiss animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }

            let panel = CinemaInputPanel(origin: mouseLocation)
            panel.onSubmit = { [weak self] showName in
                self?.cinemaInputPanel = nil
                self?.startCinemaWithContext(showName: showName)
            }
            panel.onSkip = { [weak self] in
                self?.cinemaInputPanel = nil
                self?.startCinemaWithContext(showName: nil)
            }
            self.cinemaInputPanel = panel
            panel.showAnimated()
        }
    }

    private func startCinemaWithContext(showName: String?) {
        guard let service = subtitleService else { return }

        // Resolve language FIRST so glossary generation uses the correct one
        let lang: TargetLanguage = AppSettings.shared.subtitleTranslationLanguage ?? .russian

        // Start glossary generation IMMEDIATELY (races with audio init — usually wins)
        if let showName {
            service.startGlossaryGeneration(showName: showName, isUserProvided: true, language: lang)
        }
        AppSettings.shared.subtitleDisplayMode = .cinema

        if service.isRunning {
            service.switchDisplayMode(to: .cinema)
            if AppSettings.shared.subtitleTranslationLanguage == nil {
                service.switchTranslationMode(to: lang)
            }
        } else {
            AppSettings.shared.subtitleTranslationLanguage = lang
            Task {
                service.subtitleLocale = AppSettings.shared.subtitleLanguage.locale
                await service.start()
            }
        }
    }
}

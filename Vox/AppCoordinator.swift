import SwiftUI
import Carbon.HIToolbox

@Observable
@MainActor
final class AppCoordinator {
    let viewModel = TranslationViewModel()
    private var panelController: PanelController?
    private var hotkeyService: HotkeyService?
    private var radialMenuPanel: RadialMenuPanel?

    // Set by AppDelegate after init
    weak var subtitleService: SubtitleService?

    init() {
        panelController = PanelController(viewModel: viewModel)

        hotkeyService = HotkeyService()
        hotkeyService?.start()

        // Cmd+T → Translate clipboard
        hotkeyService?.register(keyCode: kVK_ANSI_T, modifiers: cmdKey) { [weak self] in
            Task { @MainActor in
                self?.translate()
            }
        }

        // Cmd+Shift+T → Radial quick menu
        hotkeyService?.register(keyCode: kVK_ANSI_T, modifiers: cmdKey | shiftKey) { [weak self] in
            Task { @MainActor in
                self?.toggleRadialMenu()
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
                label: "Translate",
                tint: .purple,
                isActive: { false },
                action: { [weak self] in self?.translate() }
            ),
            RadialMenuItem(
                id: "subtitles",
                icon: "RadialSubtitles",
                label: "Subtitles",
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
                label: "Translation",
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
                label: "Cinema",
                tint: .orange,
                isActive: {
                    AppSettings.shared.subtitleTranslationLanguage != nil
                        && AppSettings.shared.subtitleDisplayMode == .cinema
                },
                action: { [weak self] in self?.toggleCinemaMode() }
            ),
        ]
    }
}

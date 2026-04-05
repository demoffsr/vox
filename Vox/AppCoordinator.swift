import SwiftUI

@Observable
@MainActor
final class AppCoordinator {
    let viewModel = TranslationViewModel()
    private var panelController: PanelController?
    private var hotkeyService: HotkeyService?

    init() {
        panelController = PanelController(viewModel: viewModel)

        hotkeyService = HotkeyService { [weak self] in
            Task { @MainActor in
                self?.translate()
            }
        }
        hotkeyService?.start()

        viewModel.onPanelVisibilityChanged = { [weak self] in
            self?.panelController?.updateVisibility()
        }
    }

    func translate() {
        viewModel.translateFromClipboard()
    }
}

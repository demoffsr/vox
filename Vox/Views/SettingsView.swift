import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, quickTranslation, liveTranslation, history, api, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .quickTranslation: "Quick Translation"
        case .liveTranslation: "Live Translation"
        case .history: "History"
        case .api: "API"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "App-wide behavior and keyboard shortcut."
        case .quickTranslation: "Quick translate from clipboard with ⌘T."
        case .liveTranslation: "Real-time subtitles, lecture and cinema translation."
        case .history: "Your past translations and lecture sessions."
        case .api: "Claude API key and connection."
        case .about: "Version and build information."
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .quickTranslation: "text.bubble"
        case .liveTranslation: "captions.bubble"
        case .history: "clock.arrow.circlepath"
        case .api: "key.fill"
        case .about: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .general: .blue
        case .quickTranslation: .purple
        case .liveTranslation: .mint
        case .history: .orange
        case .api: .purple
        case .about: .gray
        }
    }
}

/// Settings panel. Shares the lecture translation window's visual language:
/// compact title bar, gradient dividers between sections, single flat surface
/// (no nested cards), capsule pill buttons.
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var apiKeyInput: String = ""
    @State private var isAPIKeyVisible: Bool = false
    @State private var verificationStatus: VerificationStatus = .idle
    @State private var selected: SettingsCategory = .general

    private let keychainHelper = KeychainHelper()

    enum VerificationStatus: Equatable {
        case idle, verifying, success, failed(String)
    }

    // MARK: - Bindings

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 })
    }

    private var smartModeBinding: Binding<Bool> {
        Binding(get: { settings.smartModeEnabled }, set: { settings.smartModeEnabled = $0 })
    }

    private var selectedModelBinding: Binding<ClaudeModel> {
        Binding(get: { settings.selectedModel }, set: { settings.selectedModel = $0 })
    }

    private var subtitleLanguageBinding: Binding<SubtitleLanguage> {
        Binding(get: { settings.subtitleLanguage }, set: { settings.subtitleLanguage = $0 })
    }

    private var showNativeSubtitlesBinding: Binding<Bool> {
        Binding(get: { settings.showNativeSubtitles }, set: { settings.showNativeSubtitles = $0 })
    }

    private var defaultTranslationLanguageBinding: Binding<TargetLanguage> {
        Binding(
            get: { settings.subtitleTranslationLanguage ?? settings.primaryTargetLanguage },
            set: { settings.subtitleTranslationLanguage = $0 }
        )
    }

    private var primaryTargetLanguageBinding: Binding<TargetLanguage> {
        Binding(get: { settings.primaryTargetLanguage }, set: { settings.primaryTargetLanguage = $0 })
    }

    private var secondaryTargetLanguageBinding: Binding<TargetLanguage> {
        Binding(get: { settings.secondaryTargetLanguage }, set: { settings.secondaryTargetLanguage = $0 })
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            GradientDivider(axis: .vertical)
            contentPane
        }
        .padding(.top, 28) // room for the transparent traffic-light titlebar
        .frame(width: 660, height: 600)
        .environment(\.colorScheme, .dark)
        .onAppear {
            apiKeyInput = (try? keychainHelper.load()) ?? ""
        }
    }

    // MARK: - Sidebar

    private func sidebarItem(_ category: SettingsCategory) -> some View {
        let isSelected = selected == category
        return Button {
            selected = category
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(category.color)
                    .frame(width: 16)
                Text(category.title)
                    .font(VoxTokens.Typo.body)
                    .foregroundStyle(isSelected ? VoxTokens.Ink.primary : VoxTokens.Ink.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.06) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { category in
                sidebarItem(category)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 200, alignment: .top)
    }

    // MARK: - Content Header

    private func contentHeader(_ category: SettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VoxTokens.Ink.primary)
            Text(category.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(VoxTokens.Ink.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Content Pane

    @ViewBuilder
    private var contentPane: some View {
        VStack(spacing: 0) {
            contentHeader(selected)
            GradientDivider().padding(.horizontal, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    switch selected {
                    case .general:          generalRows
                    case .quickTranslation: quickTranslationRows
                    case .liveTranslation:  liveTranslationRows
                    case .history:          HistorySectionView()
                    case .api:              apiRows
                    case .about:            aboutRows
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 459)
    }

    // MARK: - General

    @ViewBuilder
    private var generalRows: some View {
        row(icon: "command", title: "Hotkey") {
            HStack(spacing: 3) {
                keyCap("⌘")
                keyCap("T")
            }
        }
        rowDivider
        row(icon: "power", title: "Launch at login") {
            Toggle("", isOn: launchAtLoginBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.blue)
        }
    }

    // MARK: - Quick Translation

    @ViewBuilder
    private var quickTranslationRows: some View {
        row(icon: "sparkles", title: "Smart mode") {
            Toggle("", isOn: smartModeBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.blue)
        }
        hint("Adds dictionary definitions, usage examples, and cultural notes alongside translation.")
        rowDivider
        row(icon: "globe", title: "Primary language") {
            Picker("", selection: primaryTargetLanguageBinding) {
                ForEach(TargetLanguage.allCases.filter { $0 != .auto }) { lang in
                    Text("\(lang.flag) \(lang.rawValue)").tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)
            .tint(VoxTokens.Ink.tertiary)
        }
        hint("Text is translated to this language by default.")
        rowDivider
        row(icon: "arrow.uturn.left", title: "Fallback language") {
            Picker("", selection: secondaryTargetLanguageBinding) {
                ForEach(TargetLanguage.allCases.filter { $0 != .auto }) { lang in
                    Text("\(lang.flag) \(lang.rawValue)").tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)
            .tint(VoxTokens.Ink.tertiary)
        }
        hint("Used when the text is already in your primary language.")
        rowDivider
        row(icon: "cpu", title: "Model") {
            Picker("", selection: selectedModelBinding) {
                ForEach(ClaudeModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)
            .tint(VoxTokens.Ink.tertiary)
        }
        hint("Haiku is fast and cheap. Sonnet is slower but more accurate.")
    }

    // MARK: - Live Translation

    @ViewBuilder
    private var liveTranslationRows: some View {
        row(icon: "rectangle.bottomhalf.inset.filled", title: "Overlay panel") {
            Toggle("", isOn: showNativeSubtitlesBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.blue)
        }
        hint("Show floating subtitles over any app. Safari overlay always active.")
        rowDivider
        row(icon: "waveform", title: "Source language") {
            Picker("", selection: subtitleLanguageBinding) {
                ForEach(SubtitleLanguage.allCases) { lang in
                    Text("\(lang.flag) \(lang.displayName)").tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)
            .tint(VoxTokens.Ink.tertiary)
        }
        hint("Language being spoken in the audio source.")
        rowDivider
        row(icon: "character.bubble", title: "Translate to") {
            Picker("", selection: defaultTranslationLanguageBinding) {
                ForEach(TargetLanguage.allCases.filter { $0 != .auto }) { lang in
                    Text("\(lang.flag) \(lang.rawValue)").tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 145)
            .tint(VoxTokens.Ink.tertiary)
        }
        hint("Default target for Lecture and Cinema modes. Can be changed live.")
    }

    // MARK: - API

    @ViewBuilder
    private var apiRows: some View {
        // API Key label + input
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(VoxTokens.Ink.subtle)
                    .frame(width: 16)
                Text("API Key")
                    .font(VoxTokens.Typo.body)
                    .foregroundStyle(VoxTokens.Ink.secondary)
            }

            HStack(spacing: 8) {
                Group {
                    if isAPIKeyVisible {
                        TextField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                    } else {
                        SecureField("sk-ant-...", text: $apiKeyInput)
                            .textFieldStyle(.plain)
                    }
                }
                .font(VoxTokens.Typo.mono)
                .foregroundStyle(VoxTokens.Ink.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: VoxTokens.Radius.sm, style: .continuous)
                        .fill(VoxTokens.Ink.floor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoxTokens.Radius.sm, style: .continuous)
                        .strokeBorder(VoxTokens.Ink.trace, lineWidth: 0.5)
                )

                VoxCircleIconButton(
                    icon: isAPIKeyVisible ? "eye.slash.fill" : "eye.fill",
                    size: 30
                ) {
                    isAPIKeyVisible.toggle()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        rowDivider

        HStack(spacing: 10) {
            verificationBadge
            Spacer()
            saveButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - About

    @ViewBuilder
    private var aboutRows: some View {
        row(icon: "info.circle", title: "Version") {
            Text("1.0.0")
                .font(VoxTokens.Typo.mono)
                .foregroundStyle(VoxTokens.Ink.subtle)
        }
    }

    // MARK: - Shared row / hint / divider

    private func row<Trailing: View>(
        icon: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(VoxTokens.Ink.subtle)
                .frame(width: 16)
            Text(title)
                .font(VoxTokens.Typo.body)
                .foregroundStyle(VoxTokens.Ink.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(VoxTokens.Ink.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14 + 16 + 8) // align under title
            .padding(.bottom, 6)
    }

    private var rowDivider: some View {
        GradientDivider()
            .padding(.horizontal, 14)
    }

    // MARK: - Verification Badge & Save Button

    private var verificationBadge: some View {
        Group {
            switch verificationStatus {
            case .idle:
                EmptyView()
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(VoxTokens.Ink.muted)
                    Text("Checking...")
                        .font(.system(size: 11))
                        .foregroundStyle(VoxTokens.Ink.subtle)
                }
            case .success:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Verified")
                        .foregroundStyle(.green)
                }
                .font(VoxTokens.Typo.small)
            case .failed(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red.opacity(0.8))
                    Text(msg)
                        .foregroundStyle(.red.opacity(0.8))
                }
                .font(VoxTokens.Typo.small)
            }
        }
    }

    /// Capsule Save button matching the lecture window's bottom-bar pill style.
    private var saveButton: some View {
        VoxCapsuleButton(
            "Save & Verify",
            icon: "checkmark.shield.fill",
            isDisabled: apiKeyInput.isEmpty,
            action: saveAndVerifyKey
        )
    }

    // MARK: - KeyCap

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(VoxTokens.Ink.tertiary)
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(VoxTokens.Ink.trace)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
    }

    // MARK: - Actions

    private func saveAndVerifyKey() {
        do {
            try keychainHelper.save(apiKeyInput)
        } catch {
            verificationStatus = .failed("Save failed")
            return
        }

        verificationStatus = .verifying
        Task {
            do {
                var request = URLRequest(url: Constants.apiURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                request.setValue(apiKeyInput, forHTTPHeaderField: "x-api-key")
                request.setValue(Constants.apiVersion, forHTTPHeaderField: "anthropic-version")

                let body: [String: Any] = [
                    "model": ClaudeModel.haiku.rawValue,
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": "Hi"]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    verificationStatus = .success
                } else {
                    verificationStatus = .failed("Invalid key")
                }
            } catch {
                verificationStatus = .failed("Connection error")
            }
        }
    }
}

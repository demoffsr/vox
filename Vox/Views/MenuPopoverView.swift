import SwiftUI

struct MenuPopoverView: View {
    let coordinator: AppCoordinator
    let subtitleService: SubtitleService
    let refreshLocales: () async -> Void
    let openSettings: () -> Void

    @State private var isSubtitlesOn = false
    @State private var isTranslationOn = false
    @State private var listenLang: SubtitleLanguage = .english
    @State private var translateLang: TargetLanguage = .russian
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Translate action — mirrors the lecture window's title-bar pill/row rhythm
            Button(action: { coordinator.translate() }) {
                HStack {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 13))
                        .foregroundStyle(VoxTokens.Ink.muted)
                        .frame(width: 18)
                    Text("Translate")
                        .font(VoxTokens.Typo.body)
                        .foregroundStyle(VoxTokens.Ink.primary)
                    Spacer()
                    Text("⌘T")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(VoxTokens.Ink.faint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            GradientDivider()

            // Subtitles toggle
            HStack(spacing: 8) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 12))
                    .foregroundStyle(VoxTokens.Ink.subtle)
                    .frame(width: 18)
                Text("Subtitles")
                    .font(VoxTokens.Typo.body)
                    .foregroundStyle(VoxTokens.Ink.primary)
                Spacer()
                Toggle("", isOn: subtitlesBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Subtitle language picker — only when Subtitles ON and Translation OFF
            if isSubtitlesOn && !isTranslationOn {
                subtitleLanguagePicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Translation toggle
            HStack(spacing: 8) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 12))
                    .foregroundStyle(VoxTokens.Ink.subtle)
                    .frame(width: 18)
                Text("Translation")
                    .font(VoxTokens.Typo.body)
                    .foregroundStyle(VoxTokens.Ink.primary)
                Spacer()
                Toggle("", isOn: translationBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Language pickers — only when Translation is ON
            if isTranslationOn {
                GradientDivider()

                HStack(spacing: 6) {
                    Image(systemName: "ear")
                        .font(.system(size: 11))
                        .foregroundStyle(VoxTokens.Ink.subtle)
                        .frame(width: 16)
                    Text("Listen")
                        .font(VoxTokens.Typo.small)
                        .foregroundStyle(VoxTokens.Ink.tertiary)
                    Spacer()
                    Picker("", selection: listenBinding) {
                        ForEach(SubtitleLanguage.allCases) { lang in
                            Text("\(lang.flag) \(lang.displayName)").tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .tint(VoxTokens.Ink.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(VoxTokens.Ink.subtle)
                        .frame(width: 16)
                    Text("Into")
                        .font(VoxTokens.Typo.small)
                        .foregroundStyle(VoxTokens.Ink.tertiary)
                    Spacer()
                    Picker("", selection: translateLangBinding) {
                        ForEach(TargetLanguage.allCases.filter { $0 != .auto }) { lang in
                            Text("\(lang.flag) \(lang.rawValue)").tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .tint(VoxTokens.Ink.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            GradientDivider()

            // Footer — mirrors the lecture bottom bar (capsule pills, left+right)
            HStack(spacing: 10) {
                VoxCapsuleButton("Settings", icon: "gear", action: openSettings)
                Spacer()
                VoxCapsuleButton("Quit", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: isTranslationOn)
        .animation(.easeOut(duration: 0.2), value: isSubtitlesOn)
        .onAppear {
            // Safe sync — only updates @State, does NOT trigger Binding.set
            isSubtitlesOn = subtitleService.isRunning
            isTranslationOn = AppSettings.shared.subtitleTranslationLanguage != nil
            listenLang = AppSettings.shared.subtitleLanguage
            translateLang = AppSettings.shared.subtitleTranslationLanguage ?? .russian
        }
    }

    // MARK: - Bindings (actions fire ONLY on user interaction, never from onAppear)

    private var subtitlesBinding: Binding<Bool> {
        Binding(
            get: { isSubtitlesOn },
            set: { newValue in
                isSubtitlesOn = newValue
                print("[Menu] Subtitles toggle → \(newValue)")
                Task {
                    if newValue {
                        subtitleService.subtitleLocale = AppSettings.shared.subtitleLanguage.locale
                        await subtitleService.start()
                    } else {
                        await subtitleService.stop()
                    }
                    isSubtitlesOn = subtitleService.isRunning
                    print("[Menu] After start/stop → isRunning=\(subtitleService.isRunning)")
                }
            }
        )
    }

    private var translationBinding: Binding<Bool> {
        Binding(
            get: { isTranslationOn },
            set: { newValue in
                isTranslationOn = newValue
                let running = subtitleService.isRunning
                print("[Menu] Translation toggle → \(newValue), isRunning=\(running)")
                if newValue {
                    let lang = translateLang
                    if running {
                        subtitleService.switchTranslationMode(to: lang)
                    } else {
                        AppSettings.shared.subtitleTranslationLanguage = lang
                    }
                } else {
                    if running {
                        subtitleService.switchTranslationMode(to: nil)
                    } else {
                        AppSettings.shared.subtitleTranslationLanguage = nil
                    }
                }
            }
        )
    }

    private var listenBinding: Binding<SubtitleLanguage> {
        Binding(
            get: { listenLang },
            set: { newValue in
                listenLang = newValue
                print("[Menu] Listen lang → \(newValue.displayName)")
                AppSettings.shared.subtitleLanguage = newValue
                subtitleService.subtitleLocale = newValue.locale
                if subtitleService.isRunning {
                    Task {
                        await subtitleService.stop()
                        await subtitleService.start()
                        isSubtitlesOn = subtitleService.isRunning
                    }
                }
            }
        )
    }

    private var translateLangBinding: Binding<TargetLanguage> {
        Binding(
            get: { translateLang },
            set: { newValue in
                translateLang = newValue
                print("[Menu] Translate lang → \(newValue.rawValue)")
                if subtitleService.isRunning {
                    subtitleService.switchTranslationMode(to: newValue)
                } else {
                    AppSettings.shared.subtitleTranslationLanguage = newValue
                }
            }
        )
    }

    // MARK: - Subtitle Language Picker

    private var subtitleLanguagePicker: some View {
        VStack(spacing: 0) {
            GradientDivider()

            // Language picker row
            HStack(spacing: 6) {
                Image(systemName: "ear")
                    .font(.system(size: 11))
                    .foregroundStyle(VoxTokens.Ink.subtle)
                    .frame(width: 16)
                Text("Language")
                    .font(VoxTokens.Typo.small)
                    .foregroundStyle(VoxTokens.Ink.tertiary)
                Spacer()
                Picker("", selection: subtitleLangBinding) {
                    ForEach(SubtitleLanguage.allCases) { lang in
                        let installed = AppSettings.shared.installedLocales.contains(lang.languageCode)
                        HStack {
                            Text("\(lang.flag) \(lang.displayName)")
                            if !installed {
                                Text("– not installed")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
                .tint(VoxTokens.Ink.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            // Hint: install languages + refresh
            HStack(spacing: 4) {
                Button(action: openDictationSettings) {
                    HStack(spacing: 3) {
                        Image(systemName: "globe.badge.chevron.backward")
                            .font(.system(size: 9))
                        Text("Install languages")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(VoxTokens.Ink.faint)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    isRefreshing = true
                    Task {
                        await refreshLocales()
                        isRefreshing = false
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                        Text("Refresh")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(VoxTokens.Ink.faint)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    /// Binding that opens Keyboard Settings when user picks an uninstalled language.
    private var subtitleLangBinding: Binding<SubtitleLanguage> {
        Binding(
            get: { listenLang },
            set: { newValue in
                let installed = AppSettings.shared.installedLocales.contains(newValue.languageCode)
                guard installed else {
                    openDictationSettings()
                    return
                }
                listenLang = newValue
                AppSettings.shared.subtitleLanguage = newValue
                subtitleService.subtitleLocale = newValue.locale
                if subtitleService.isRunning {
                    Task {
                        await subtitleService.stop()
                        await subtitleService.start()
                        isSubtitlesOn = subtitleService.isRunning
                    }
                }
            }
        )
    }

    private func openDictationSettings() {
        // Open System Settings → Keyboard (Dictation section is at the bottom)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

}

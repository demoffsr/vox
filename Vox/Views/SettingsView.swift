import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var apiKeyInput: String = ""
    @State private var isAPIKeyVisible: Bool = false
    @State private var verificationStatus: VerificationStatus = .idle

    private let keychainHelper = KeychainHelper()

    enum VerificationStatus: Equatable {
        case idle
        case verifying
        case success
        case failed(String)
    }

    // Bindings for computed properties on AppSettings
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { settings.launchAtLogin = $0 }
        )
    }

    private var smartModeBinding: Binding<Bool> {
        Binding(
            get: { settings.smartModeEnabled },
            set: { settings.smartModeEnabled = $0 }
        )
    }

    private var selectedModelBinding: Binding<ClaudeModel> {
        Binding(
            get: { settings.selectedModel },
            set: { settings.selectedModel = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsCard("General") {
                    settingsRow("Hotkey") {
                        Text("⌘⇧T")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    settingsRow("Launch at login") {
                        Toggle("", isOn: launchAtLoginBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                settingsCard("Translation") {
                    settingsRow("Smart mode") {
                        Toggle("", isOn: smartModeBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                settingsCard("API") {
                    settingsRow("API Key") {
                        HStack(spacing: 6) {
                            if isAPIKeyVisible {
                                TextField("sk-ant-...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 200)
                            } else {
                                SecureField("sk-ant-...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 200)
                            }
                            Button(action: { isAPIKeyVisible.toggle() }) {
                                Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider()
                    settingsRow("Model") {
                        Picker("", selection: selectedModelBinding) {
                            ForEach(ClaudeModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .frame(width: 160)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Save & Verify Key") {
                            saveAndVerifyKey()
                        }
                        .disabled(apiKeyInput.isEmpty)
                        .controlSize(.small)

                        if verificationStatus == .verifying {
                            ProgressView()
                                .controlSize(.small)
                        } else if verificationStatus == .success {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if case .failed(let msg) = verificationStatus {
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 11))
                        }
                    }
                    .padding(.top, 4)
                }

                settingsCard("About") {
                    settingsRow("Version") {
                        Text("Vox 1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 460)
        .onAppear {
            apiKeyInput = (try? keychainHelper.load()) ?? ""
        }
    }

    private func settingsCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
            )
        }
    }

    private func settingsRow(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            trailing()
        }
    }

    private func saveAndVerifyKey() {
        do {
            try keychainHelper.save(apiKeyInput)
        } catch {
            verificationStatus = .failed("Failed to save key")
            return
        }

        verificationStatus = .verifying
        Task {
            do {
                let request = try ClaudeAPIService.buildRequest(
                    text: "Hello",
                    model: .haiku,
                    apiKey: apiKeyInput
                )
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

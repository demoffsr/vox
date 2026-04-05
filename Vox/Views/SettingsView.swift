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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 })
    }

    private var smartModeBinding: Binding<Bool> {
        Binding(get: { settings.smartModeEnabled }, set: { settings.smartModeEnabled = $0 })
    }

    private var selectedModelBinding: Binding<ClaudeModel> {
        Binding(get: { settings.selectedModel }, set: { settings.selectedModel = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Vox")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Settings")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            Divider().opacity(0.3)

            ScrollView {
                VStack(spacing: 20) {
                    // General
                    cardSection("General", icon: "gearshape") {
                        row("Hotkey") {
                            HStack(spacing: 2) {
                                keyCapView("⌘")
                                keyCapView("T")
                            }
                        }
                        Divider().opacity(0.2)
                        row("Launch at login") {
                            Toggle("", isOn: launchAtLoginBinding)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(.blue)
                        }
                    }

                    // Translation
                    cardSection("Translation", icon: "text.bubble") {
                        row("Smart mode") {
                            Toggle("", isOn: smartModeBinding)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .tint(.blue)
                        }
                        Text("Detects code, errors, and legal text for context-aware translation")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }

                    // API
                    cardSection("API", icon: "key") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("API Key")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))

                            HStack(spacing: 8) {
                                Group {
                                    if isAPIKeyVisible {
                                        TextField("sk-ant-...", text: $apiKeyInput)
                                    } else {
                                        SecureField("sk-ant-...", text: $apiKeyInput)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                                )

                                Button(action: { isAPIKeyVisible.toggle() }) {
                                    Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(.white.opacity(0.06)))
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider().opacity(0.2)

                        row("Model") {
                            Picker("", selection: selectedModelBinding) {
                                ForEach(ClaudeModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150)
                        }

                        Divider().opacity(0.2)

                        HStack {
                            Spacer()

                            if verificationStatus == .verifying {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white.opacity(0.5))
                            } else if verificationStatus == .success {
                                Label("Verified", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.green)
                            } else if case .failed(let msg) = verificationStatus {
                                Label(msg, systemImage: "xmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.red)
                            }

                            Button(action: saveAndVerifyKey) {
                                Text("Save & Verify")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(.blue.opacity(apiKeyInput.isEmpty ? 0.3 : 0.8))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(apiKeyInput.isEmpty)
                        }
                    }

                    // About
                    cardSection("About", icon: "info.circle") {
                        row("Version") {
                            Text("1.0")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Divider().opacity(0.2)
                        row("Powered by") {
                            Text("Claude API")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 520)
        .background(.ultraThinMaterial.opacity(0.8))
        .environment(\.colorScheme, .dark)
        .onAppear {
            apiKeyInput = (try? keychainHelper.load()) ?? ""
        }
    }

    // MARK: - Components

    private func cardSection(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .tracking(0.8)
            }

            VStack(spacing: 0) {
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            )
        }
    }

    private func row(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            trailing()
        }
    }

    private func keyCapView(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            .frame(minWidth: 22, minHeight: 20)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
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

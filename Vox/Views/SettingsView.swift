import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var apiKeyInput: String = ""
    @State private var isAPIKeyVisible: Bool = false
    @State private var verificationStatus: VerificationStatus = .idle
    @State private var isHovering = false

    private let keychainHelper = KeychainHelper()

    enum VerificationStatus: Equatable {
        case idle, verifying, success, failed(String)
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
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.12),
                    Color(red: 0.05, green: 0.05, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.top, 24)
                    .padding(.bottom, 20)

                // Content
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        generalSection
                        translationSection
                        apiSection
                        aboutSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(width: 440, height: 540)
        .environment(\.colorScheme, .dark)
        .onAppear {
            apiKeyInput = (try? keychainHelper.load()) ?? ""
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.6), .purple.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
            .shadow(color: .blue.opacity(0.3), radius: 12, y: 4)

            Text("Vox")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("AI Translator")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: - General

    private var generalSection: some View {
        card {
            row(icon: "command", title: "Hotkey") {
                HStack(spacing: 3) {
                    keyCap("⌘")
                    keyCap("T")
                }
            }

            divider

            row(icon: "power", title: "Launch at login") {
                Toggle("", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.blue)
            }
        }
    }

    // MARK: - Translation

    private var translationSection: some View {
        card {
            row(icon: "sparkles", title: "Smart mode") {
                Toggle("", isOn: smartModeBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(.blue)
            }

            Text("Code → translates comments only. Errors → translates + explains.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.top, 4)
                .padding(.leading, 28)
        }
    }

    // MARK: - API

    private var apiSection: some View {
        card {
            // API Key
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 16)
                    Text("API Key")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }

                HStack(spacing: 8) {
                    ZStack {
                        if isAPIKeyVisible {
                            TextField("sk-ant-...", text: $apiKeyInput)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField("sk-ant-...", text: $apiKeyInput)
                                .textFieldStyle(.plain)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    )

                    iconButton(isAPIKeyVisible ? "eye.slash.fill" : "eye.fill") {
                        isAPIKeyVisible.toggle()
                    }
                }
            }

            divider

            // Model
            row(icon: "cpu", title: "Model") {
                Picker("", selection: selectedModelBinding) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 145)
                .tint(.white.opacity(0.7))
            }

            divider

            // Save button
            HStack {
                verificationBadge
                Spacer()
                saveButton
            }
        }
    }

    private var verificationBadge: some View {
        Group {
            switch verificationStatus {
            case .idle:
                EmptyView()
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.5))
                    Text("Checking...").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            case .success:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Verified")
                        .foregroundStyle(.green)
                }
                .font(.system(size: 12, weight: .medium))
            case .failed(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red.opacity(0.8))
                    Text(msg)
                        .foregroundStyle(.red.opacity(0.8))
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    private var saveButton: some View {
        Button(action: saveAndVerifyKey) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11))
                Text("Save & Verify")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: apiKeyInput.isEmpty
                                ? [.gray.opacity(0.3), .gray.opacity(0.2)]
                                : [.blue, .blue.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .shadow(color: apiKeyInput.isEmpty ? .clear : .blue.opacity(0.3), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(apiKeyInput.isEmpty)
    }

    // MARK: - About

    private var aboutSection: some View {
        card {
            row(icon: "info.circle", title: "Version") {
                Text("1.0.0")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // MARK: - Reusable Components

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func row(icon: String, title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            trailing()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.04))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private func keyCap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.08))
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

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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

import SafariServices
import Foundation

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem

        let message: [String: Any]
        if #available(macOS 14.0, *) {
            message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        } else {
            message = (item?.userInfo?["message"] ?? item?.userInfo?[SFExtensionMessageKey]) as? [String: Any] ?? [:]
        }

        let action = message["action"] as? String ?? ""

        switch action {
        case "translate":
            handleTranslate(message: message, context: context)
        case "ping":
            respond(with: ["status": "ok"], context: context)
        case "startSubtitles":
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.vox.startSubtitles"), object: nil, userInfo: nil, deliverImmediately: true)
            respond(with: ["status": "started"], context: context)
        case "stopSubtitles":
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.vox.stopSubtitles"), object: nil, userInfo: nil, deliverImmediately: true)
            respond(with: ["status": "stopped"], context: context)
        case "getSubtitleUpdate":
            let result = readSubtitleState()
            respond(with: result, context: context)
        default:
            respond(with: ["error": "Unknown action: \(action)"], context: context)
        }
    }

    private func handleTranslate(message: [String: Any], context: NSExtensionContext) {
        guard let text = message["text"] as? String, !text.isEmpty else {
            respond(with: ["error": "No text provided"], context: context)
            return
        }

        let targetLang = message["targetLanguage"] as? String ?? "Auto"
        let language = TargetLanguage(rawValue: targetLang) ?? .auto

        // Load API key from keychain
        let keychain = KeychainHelper(accessGroup: nil)
        guard let apiKey = try? keychain.load(), !apiKey.isEmpty else {
            respond(with: ["error": "No API key. Open Vox → Settings to add your key."], context: context)
            return
        }

        let modelRaw = UserDefaults.standard.string(forKey: "selectedModel") ?? ClaudeModel.haiku.rawValue
        let model = ClaudeModel(rawValue: modelRaw) ?? .haiku

        Task {
            do {
                var request = try ClaudeAPIService.buildRequest(
                    text: text,
                    model: model,
                    apiKey: apiKey,
                    targetLanguage: language
                )
                // Non-streaming for extension
                var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                body["stream"] = false
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let msg = code == 401 ? "Invalid API key" : code == 429 ? "Rate limited" : "API error (\(code))"
                    self.respond(with: ["error": msg], context: context)
                    return
                }

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let content = json?["content"] as? [[String: Any]]
                let translatedText = content?.first?["text"] as? String ?? ""

                self.respond(with: ["translation": translatedText], context: context)
            } catch {
                self.respond(with: ["error": error.localizedDescription], context: context)
            }
        }
    }

    // MARK: - Subtitle State

    private func readSubtitleState() -> [String: Any] {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.Vox.Vox") else {
            NSLog("[Vox Extension] No container for group.com.Vox.Vox")
            return ["text": "", "timestamp": 0, "status": "stopped"]
        }
        let file = container.appendingPathComponent("vox-subtitles.json")
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[Vox Extension] Failed to read: %@", file.path)
            return ["text": "", "timestamp": 0, "status": "stopped"]
        }
        NSLog("[Vox Extension] Read subtitle: %@", (dict["text"] as? String) ?? "(empty)")
        return dict
    }

    private func respond(with message: [String: Any], context: NSExtensionContext) {
        let response = NSExtensionItem()
        if #available(macOS 14.0, *) {
            response.userInfo = [SFExtensionMessageKey: message]
        } else {
            response.userInfo = ["message": message]
        }
        context.completeRequest(returningItems: [response])
    }
}

import Foundation
import AppKit

/// Fetches images via DuckDuckGo image search or Open Graph link previews.
final class ImageSearchService {

    /// Search DuckDuckGo for images matching the query. Returns up to 8 results.
    func searchImages(query: String) async -> [ImageItem] {
        guard let vqd = await fetchVQDToken(for: query) else { return [] }
        return await fetchImages(query: query, vqd: vqd)
    }

    /// Fetch Open Graph preview for a URL (image + title).
    func fetchLinkPreview(url: URL) async -> ImageItem? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) ?? ""

            let ogImage = Self.extractMeta(html: html, property: "og:image")
            let ogTitle = Self.extractMeta(html: html, property: "og:title")
                ?? Self.extractHTMLTitle(html: html)

            guard let imageString = ogImage, let imageURL = URL(string: imageString) else { return nil }

            return ImageItem(
                imageURL: imageURL,
                fullImageURL: imageURL,
                title: ogTitle ?? url.host ?? "",
                sourceURL: url
            )
        } catch {
            return nil
        }
    }

    /// Copy image from URL to the system clipboard.
    static func copyImageToClipboard(from url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data) else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            return true
        } catch {
            return false
        }
    }

    /// Returns true if the text looks like a URL.
    static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || (trimmed.contains(".") && !trimmed.contains(" ") && trimmed.count > 4
                && (trimmed.contains(".com") || trimmed.contains(".org") || trimmed.contains(".net")
                    || trimmed.contains(".io") || trimmed.contains(".ru") || trimmed.contains(".dev")))
    }

    // MARK: - DuckDuckGo internals

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Step 1: POST to DuckDuckGo to get a VQD token for image search.
    private func fetchVQDToken(for query: String) async -> String? {
        guard let url = URL(string: "https://duckduckgo.com") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = "q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            // Try header first
            if let vqd = http.value(forHTTPHeaderField: "x-vqd-4"), !vqd.isEmpty {
                return vqd
            }

            // Fallback: parse from HTML body
            let body = String(data: data, encoding: .utf8) ?? ""
            if let range = body.range(of: #"vqd=([0-9]+-[0-9]+(-[0-9]+)?)"#, options: .regularExpression) {
                let match = String(body[range])
                return String(match.dropFirst(4)) // drop "vqd="
            }

            return nil
        } catch {
            return nil
        }
    }

    /// Step 2: Fetch image results from DuckDuckGo's image search API.
    private func fetchImages(query: String, vqd: String) async -> [ImageItem] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }

        let urlString = "https://duckduckgo.com/i.js"
            + "?l=wt-wt&o=json&q=\(encoded)&vqd=\(vqd)"
            + "&f=,,,,,&p=-1"

        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://duckduckgo.com", forHTTPHeaderField: "Referer")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]]
            else { return [] }

            return results.prefix(10).compactMap { result -> ImageItem? in
                guard let fullURLString = result["image"] as? String,
                      let fullURL = URL(string: fullURLString),
                      let title = result["title"] as? String
                else { return nil }

                let thumbnailURL = (result["thumbnail"] as? String).flatMap { URL(string: $0) }
                let sourceURL = (result["url"] as? String).flatMap { URL(string: $0) }

                return ImageItem(
                    imageURL: thumbnailURL ?? fullURL,
                    fullImageURL: fullURL,
                    title: Self.cleanHTMLEntities(title),
                    sourceURL: sourceURL
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - HTML helpers

    private static func extractMeta(html: String, property: String) -> String? {
        let patterns = [
            #"<meta[^>]*(?:property|name)\s*=\s*["']\#(property)["'][^>]*content\s*=\s*["']([^"']*)["']"#,
            #"<meta[^>]*content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']\#(property)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let match = regex.firstMatch(in: html, range: range) {
                // Get the last capture group (content value)
                let groupIndex = match.numberOfRanges - 1
                if let valueRange = Range(match.range(at: groupIndex), in: html) {
                    let value = String(html[valueRange])
                    return value.isEmpty ? nil : value
                }
            }
        }
        return nil
    }

    private static func extractHTMLTitle(html: String) -> String? {
        let pattern = #"<title[^>]*>([^<]+)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let title = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func cleanHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }
}

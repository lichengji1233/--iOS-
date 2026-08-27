import Foundation

enum UrlUtils {

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s\u4e00-\u9fff，。！？、；：“”‘’（）【】《》<>]+"#,
        options: [.caseInsensitive]
    )

    private static let schemelessRegex = try! NSRegularExpression(
        pattern: #"(?:www\.)?(?:xhslink|xiaohongshu|rednote|douyin|iesdouyin|bilibili|b23)\.(?:com|cn|tv)/[^\s\u4e00-\u9fff，。！？、；：“”‘’（）【】《》<>]+"#,
        options: [.caseInsensitive]
    )

    private static let trailing = CharacterSet(charactersIn: ")]}。,，\"'`>〉）")

    static func extractUrl(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsT = t as NSString
        if let r = urlRegex.firstMatch(in: t, range: NSRange(location: 0, length: nsT.length)),
           r.range.length == nsT.length {
            return normalizeScheme(t)
        }
        if let u = match(urlRegex, in: text) {
            let trimmed = (u.value as NSString)
                .trimmingCharacters(in: trailing)
            return normalizeScheme(trimmed)
        }
        if let u = match(schemelessRegex, in: text) {
            let trimmed = (u.value as NSString)
                .trimmingCharacters(in: trailing)
            return normalizeScheme("https://" + trimmed)
        }
        return nil
    }

    static func detectPlatform(_ url: String) -> Platform {
        let u = url.lowercased()
        if u.contains("douyin.com") || u.contains("iesdouyin.com") { return .douyin }
        if u.contains("xiaohongshu") || u.contains("xhslink") || u.contains("rednote") {
            return .xiaohongshu
        }
        if u.contains("bilibili.com") || u.contains("b23.tv") { return .bilibili }
        return .unknown
    }

    static func resolveRedirect(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { return url }
        var request = URLRequest(url: u)
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, let final = http.url {
            return final.absoluteString
        }
        return url
    }

    static func httpGet(_ url: String,
                        headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw ParseError("无效链接") }
        var request = URLRequest(url: u)
        request.timeoutInterval = 30
        request.setValue(UA.desktop, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw ParseError("网络请求失败")
        }
        return (data, http)
    }

    enum UA {
        static let desktop =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        static let mobile =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    }

    // MARK: - helpers

    private static func normalizeScheme(_ url: String) -> String {
        let s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("https://") { return "https://" + s.dropFirst(8) }
        if lower.hasPrefix("http://") { return "http://" + s.dropFirst(7) }
        return s
    }

    private static func match(_ regex: NSRegularExpression, in text: String) -> (value: String, range: NSRange)? {
        let ns = text as NSString
        guard let r = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (ns.substring(with: r.range), r.range)
    }
}

import Foundation

enum UrlUtils {

    // MARK: - 正则

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s\u4e00-\u9fff，。！？、；：“”‘’（）【】《》<>]+"#,
        options: [.caseInsensitive]
    )

    private static let bareHostRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9][A-Za-z0-9.\-]*\.[A-Za-z]{2,}(?:/[^\s]*)?$"#
    )

    private static let noteIdRegex = try! NSRegularExpression(
        pattern: #"/(?:explore|discovery/item|item|notes)/[0-9a-fA-F]{24}"#
    )

    private static let trailingJunk =
        CharacterSet(charactersIn: ")]}。，,\"'`>〉）、；")

    private static let leadingJunk =
        CharacterSet(charactersIn: "([{“‘〈《（【")

    // MARK: - 链接提取

    /// 把整段分享文字里所有像链接的片段都找出来（去掉首尾多余标点）
    static func extractUrls(from text: String) -> [String] {
        var out: [String] = []
        let ns = text as NSString
        let matches = urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let raw = ns.substring(with: m.range).trimmingCharacters(in: trailingJunk)
            let u = normalizeScheme(raw)
            if !u.isEmpty && !out.contains(u) { out.append(u) }
        }
        if !out.isEmpty { return out }

        // 兜底：整段文字里没有 http:// 前缀时，按空白切分找裸地址
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
        for piece in pieces {
            if piece.isEmpty { continue }
            let token = piece
                .trimmingCharacters(in: leadingJunk)
                .trimmingCharacters(in: trailingJunk)
            if token.isEmpty || !token.contains(".") { continue }
            if matches(bareHostRegex, token) {
                let u = "https://" + token
                if !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    /// 挑出要解析的那条链接：优先能认出平台的，认不出才退回第一条
    static func extractUrl(from text: String) -> String? {
        let all = extractUrls(from: text)
        if all.isEmpty { return nil }
        for u in all where detectPlatform(u) != .unknown {
            return u
        }
        return all.first
    }

    // MARK: - 平台识别

    static func detectPlatform(_ url: String) -> Platform {
        domainPlatform(hostOf(url)) ?? .unknown
    }

    /// 结合整段分享文字再判断一次（域名没见过的兜底）
    static func detectPlatform(_ url: String, text: String) -> Platform {
        let direct = detectPlatform(url)
        if direct != .unknown { return direct }

        let lower = (url + " " + text).lowercased()
        if lower.contains("xhslink") || lower.contains("xiaohongshu") ||
            lower.contains("rednote") || text.contains("小红书") {
            return .xiaohongshu
        }
        if lower.contains("douyin") || lower.contains("iesdouyin") || text.contains("抖音") {
            return .douyin
        }
        if lower.contains("bilibili") || lower.contains("b23.tv") ||
            text.contains("哔哩哔哩") || text.contains("B站") {
            return .bilibili
        }
        if lower.contains("weibo") || text.contains("微博") { return .weibo }
        if lower.contains("twitter") || text.contains("推特") { return .x }
        if lower.contains("instagram") { return .instagram }
        // 链接里带 24 位十六进制笔记ID 的，基本就是小红书
        if matches(noteIdRegex, url) { return .xiaohongshu }
        return .unknown
    }

    static func hostOf(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        for sep in ["/", "?", "#"] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        if let at = s.range(of: "@", options: .backwards) { s = String(s[at.upperBound...]) }
        if let colon = s.range(of: ":") { s = String(s[..<colon.lowerBound]) }
        for prefix in ["www.", "m.", "mobile."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        return s
    }

    private static func domainPlatform(_ host: String) -> Platform? {
        func isDomain(_ base: String) -> Bool {
            host == base || host.hasSuffix("." + base)
        }

        if isDomain("douyin.com") || host.hasSuffix("iesdouyin.com") ||
            host.hasSuffix("douyin.cn") || host.hasSuffix("snssdk.com") {
            return .douyin
        }
        if isDomain("xiaohongshu.com") || host.hasSuffix("xiaohongshu.cn") ||
            isDomain("xhslink.com") || host.hasSuffix("xhslink.cn") ||
            host.hasSuffix("xhslink.com.cn") || host.hasSuffix("xhs.link") ||
            isDomain("rednote.com") || host.hasSuffix("xhscdn.com") {
            return .xiaohongshu
        }
        if isDomain("bilibili.com") || isDomain("b23.tv") || host.hasSuffix("bili2233.cn") {
            return .bilibili
        }
        if isDomain("weibo.com") || isDomain("weibo.cn") ||
            host.hasSuffix("weibointl.com") || host == "t.cn" {
            return .weibo
        }
        if isDomain("x.com") || isDomain("twitter.com") || host == "t.co" {
            return .x
        }
        if isDomain("instagram.com") || host == "instagr.am" { return .instagram }
        return nil
    }

    // MARK: - 网络请求

    /// 共享会话：保留 Cookie（小红书 / 微博需要），不缓存
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// 手动逐跳记录跳转地址：分享短链的中间跳里带着 xsec_token 等关键参数，不能只取最终地址
    static func resolveRedirectChain(_ url: String, mobile: Bool = false) async -> [String] {
        guard let u = URL(string: url) else { return [url] }
        var request = URLRequest(url: u)
        request.timeoutInterval = 20
        request.setValue(mobile ? UA.mobile : UA.desktop, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if url.contains("xhslink") {
            request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        } else if url.contains("weibo") || url.contains("t.cn") {
            request.setValue("https://m.weibo.cn/", forHTTPHeaderField: "Referer")
        }

        let recorder = RedirectRecorder()
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: recorder, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var chain = [url]
        if let (_, response) = try? await session.data(for: request),
           let final = response.url?.absoluteString, !chain.contains(final) {
            chain.append(final)
        }
        // 记录到的中间跳转插在最后一条之前
        var out: [String] = [url]
        for hop in recorder.chain where !out.contains(hop) { out.append(hop) }
        if let last = chain.last, !out.contains(last) { out.append(last) }
        return out
    }

    /// 只取最终地址
    static func resolveRedirect(_ url: String) async throws -> String {
        let chain = await resolveRedirectChain(url)
        return chain.last ?? url
    }

    static func httpGet(_ url: String,
                        mobile: Bool = false,
                        referer: String? = nil,
                        headers extra: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw ParseError("无效链接") }
        var request = URLRequest(url: u)
        request.timeoutInterval = 30
        request.setValue(mobile ? UA.mobile : UA.desktop, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        for (k, v) in extra { request.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: request)
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
        static let iphone =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    // MARK: - 小工具

    private static func normalizeScheme(_ url: String) -> String {
        let s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("https://") { return "https://" + s.dropFirst(8) }
        if lower.hasPrefix("http://") { return "http://" + s.dropFirst(7) }
        return s
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }
}

/// 记录每一次 HTTP 跳转的地址（仍然继续跟随）
final class RedirectRecorder: NSObject, URLSessionTaskDelegate {
    private(set) var chain: [String] = []
    private let lock = NSLock()

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url?.absoluteString {
            lock.lock()
            if !chain.contains(u) { chain.append(u) }
            lock.unlock()
        }
        completionHandler(request)
    }
}

import Foundation

/// 微博解析器。
///
/// 微博对未登录访问要先发一张"访客 Cookie"（SUB/SUBP），拿到之后
/// m.weibo.cn/statuses/show 就能读到正文、原图和原视频地址，不需要登录账号。
struct WeiboParser {

    private let base62 = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private let headers = [
        "Referer": "https://m.weibo.cn/",
        "X-Requested-With": "XMLHttpRequest",
        "Accept": "application/json, text/plain, */*",
        "mweibo-pwa": "1",
    ]

    private static var visitorReady = false

    func parse(_ url: String) async throws -> ParseResult {
        let chain = await UrlUtils.resolveRedirectChain(url, mobile: true)
        var mid: String?
        for candidate in chain.reversed() {
            if let found = extractMid(candidate) {
                mid = found
                break
            }
        }
        guard let statusId = mid else {
            throw ParseError("未能在链接中找到微博ID，请确认分享链接完整")
        }

        await ensureVisitorCookie()

        guard let data = try? await fetchStatus(statusId) else {
            throw ParseError("无法连接微博，请检查网络后重试")
        }
        return try buildResult(data, mid: statusId)
    }

    // MARK: - 链接解析

    private func extractMid(_ url: String) -> String? {
        if let m = WebPage.firstMatch(#"/(?:detail|status|statuses|item)/(\d{15,20})"#, in: url) {
            return m
        }
        if let m = WebPage.firstMatch(#"[:/](\d{15,20})(?:$|\?|&)"#, in: url) {
            return m
        }
        if let m = WebPage.firstMatch(#"[?&](?:id|mid|status_id)=(\d{15,20})"#, in: url) {
            return m
        }
        // weibo.com/1642909335/NqWk3fXaB → 把短ID还原成数字ID
        if let code = WebPage.firstMatch(#"weibo\.(?:com|cn)/(?:\d{5,12}/)?([A-Za-z0-9]{7,12})"#, in: url) {
            return base62ToMid(code)
        }
        return nil
    }

    /// 微博详情页短ID（base62）还原成数字ID：从末尾每 4 个字符一组，非末组补足 7 位
    private func base62ToMid(_ code: String) -> String? {
        if code.isEmpty { return nil }
        let chars = Array(code)
        var out = ""
        var i = chars.count - 4
        while i > -4 {
            let from = max(0, i)
            let to = i + 4
            if to > chars.count { return nil }
            var value = 0
            for index in from..<to {
                guard let digit = base62.firstIndex(of: chars[index]) else { return nil }
                value = value * 62 + digit
            }
            var part = String(value)
            if from > 0 {
                while part.count < 7 { part = "0" + part }
            }
            out = part + out
            i -= 4
        }
        return out.count >= 15 ? out : nil
    }

    // MARK: - 访客身份

    private func ensureVisitorCookie() async {
        if Self.visitorReady { return }
        guard let tid = await requestVisitorTid() else { return }
        guard let data = await incarnate(tid) else { return }
        let sub = str(data, "sub")
        let subp = str(data, "subp")
        guard !sub.isEmpty else { return }
        let expires = Date().addingTimeInterval(24 * 3600)
        for domain in [".weibo.cn", ".weibo.com"] {
            setCookie(name: "SUB", value: sub, domain: domain, expires: expires)
            if !subp.isEmpty {
                setCookie(name: "SUBP", value: subp, domain: domain, expires: expires)
            }
        }
        Self.visitorReady = true
    }

    private func setCookie(name: String, value: String, domain: String, expires: Date) {
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
            .expires: expires,
        ]
        if let cookie = HTTPCookie(properties: props) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private func requestVisitorTid() async -> String? {
        guard let url = URL(string: "https://passport.weibo.com/visitor/genvisitor") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(UrlUtils.UA.mobile, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://passport.weibo.com/visitor/visitor", forHTTPHeaderField: "Referer")
        request.httpBody = "cb=gen_callback&fp=%7B%7D".data(using: .utf8)

        guard let (data, _) = try? await UrlUtils.session.data(for: request),
              let text = String(data: data, encoding: .utf8),
              let json = jsonpPayload(text) else { return nil }
        return str(obj(json, "data"), "tid")
    }

    private func incarnate(_ tid: String) async -> [String: Any]? {
        var components = URLComponents(string: "https://passport.weibo.com/visitor/visitor")
        components?.queryItems = [
            URLQueryItem(name: "a", value: "incarnate"),
            URLQueryItem(name: "t", value: tid),
            URLQueryItem(name: "w", value: "2"),
            URLQueryItem(name: "c", value: "095"),
            URLQueryItem(name: "gc", value: ""),
            URLQueryItem(name: "cb", value: "cross_domain"),
            URLQueryItem(name: "from", value: "weibo"),
            URLQueryItem(name: "url", value: "https://m.weibo.cn"),
            URLQueryItem(name: "domain", value: ".weibo.cn"),
            URLQueryItem(name: "_rand", value: String(Double.random(in: 0..<1))),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(UrlUtils.UA.mobile, forHTTPHeaderField: "User-Agent")
        request.setValue("https://passport.weibo.com/visitor/visitor", forHTTPHeaderField: "Referer")

        guard let (data, _) = try? await UrlUtils.session.data(for: request),
              let text = String(data: data, encoding: .utf8),
              let json = jsonpPayload(text) else { return nil }
        return obj(json, "data")
    }

    private func jsonpPayload(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"), start < end else {
            return jsonObject(text)
        }
        let inner = String(text[text.index(after: start)..<end])
        return jsonObject(inner)
    }

    // MARK: - 取数

    private func fetchStatus(_ mid: String) async throws -> [String: Any] {
        let (data, _) = try await UrlUtils.httpGet(
            "https://m.weibo.cn/statuses/show?id=\(mid)",
            mobile: true,
            referer: "https://m.weibo.cn/",
            headers: headers
        )
        guard let json = try? jsonObject(data), let payload = obj(json, "data") else {
            throw ParseError("微博返回了异常内容，请稍后重试")
        }
        return payload
    }

    // MARK: - 结果组装

    private func buildResult(_ data: [String: Any], mid: String) throws -> ParseResult {
        let caption = buildCaption(data)
        var title = caption.components(separatedBy: "\n").first ?? ""
        if title.isEmpty { title = "微博" }
        let author = str(obj(data, "user"), "screen_name")
        let safe = safeName(title, fallback: "weibo")
        var items: [MediaItem] = []

        if let pics = arr(data, "pics") {
            for (i, raw) in pics.enumerated() {
                guard let pic = raw as? [String: Any] else { continue }
                let candidates = [
                    fixUrl(str(obj(pic, "large"), "url")),
                    fixUrl(str(pic, "url")),
                ].filter { !$0.isEmpty }
                guard let first = candidates.first, let url = URL(string: first) else { continue }
                items.append(MediaItem(
                    id: "\(mid)_img\(i)", kind: .image,
                    label: "原图 \(i + 1)", fileName: "\(safe)_\(i + 1).jpg",
                    url: url, text: nil, altUrls: Array(candidates.dropFirst())
                ))
            }
        }

        if let pageInfo = obj(data, "page_info") {
            let candidates = videoCandidates(pageInfo)
            if let first = candidates.first, let url = URL(string: first) {
                items.append(MediaItem(
                    id: "\(mid)_video", kind: .video, label: "原视频",
                    fileName: "\(safe).mp4", url: url, text: nil,
                    altUrls: candidates.filter { $0 != first }
                ))
            }
        }

        if items.isEmpty && caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ParseError("这条微博读不到内容，请确认链接是否有效")
        }

        items.append(MediaItem(
            id: "\(mid)_cap", kind: .caption, label: "原文案",
            fileName: "\(safe)_文案.txt", url: nil, text: caption
        ))
        return ParseResult(platform: .weibo, title: title, author: author, caption: caption, items: items)
    }

    private func buildCaption(_ data: [String: Any]) -> String {
        let longText = str(data, "longTextContent")
        let source = longText.isEmpty ? str(data, "text") : longText
        let plain = WebPage.stripHtml(source)
        guard let retweeted = obj(data, "retweeted_status") else { return plain }
        let originAuthor = str(obj(retweeted, "user"), "screen_name")
        let originText = WebPage.stripHtml(
            str(retweeted, "longTextContent").isEmpty
                ? str(retweeted, "text") : str(retweeted, "longTextContent")
        )
        if originText.isEmpty { return plain }
        return plain + "\n\n—— 转发自 @\(originAuthor) ——\n" + originText
    }

    private func videoCandidates(_ pageInfo: [String: Any]) -> [String] {
        if str(pageInfo, "type") != "video" { return [] }
        var out: [String] = []
        if let urls = obj(pageInfo, "urls") {
            for key in ["mp4_720p_mp4", "mp4_hd_mp4", "mp4_ld_mp4", "mp4_mp4_hd"] {
                let value = fixUrl(str(urls, key))
                if !value.isEmpty && !out.contains(value) { out.append(value) }
            }
        }
        if let media = obj(pageInfo, "media_info") {
            for key in ["stream_url_hd", "stream_url", "mp4_720p_mp4", "mp4_hd_url",
                        "mp4_sd_url", "h265_mp4_hd", "h265_mp4_ld"] {
                let value = fixUrl(str(media, key))
                if !value.isEmpty && !out.contains(value) { out.append(value) }
            }
        }
        return out
    }
}

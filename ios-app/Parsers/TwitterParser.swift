import Foundation

/// X（原 Twitter）解析器。
///
/// X 官方接口都要登录，这里用公开的 fxtwitter / vxtwitter 镜像取推文数据；
/// 失败时退回 X 官方的 syndication 接口（嵌入推文用的那个）。
struct TwitterParser {

    private let headers = [
        "Accept": "application/json",
    ]

    func parse(_ url: String) async throws -> ParseResult {
        let chain = await UrlUtils.resolveRedirectChain(url, mobile: false)
        var statusId: String?
        for candidate in chain.reversed() {
            if let found = extractStatusId(candidate) {
                statusId = found
                break
            }
        }
        guard let id = statusId else {
            throw ParseError("未能在链接中找到推文编号，请确认链接完整")
        }

        if let tweet = await fetchFromMirror(id) {
            return try buildResult(tweet, statusId: id)
        }
        if let tweet = await fetchFromSyndication(id) {
            return try buildResult(tweet, statusId: id)
        }
        throw ParseError(
            "无法获取推文内容。\n\n常见原因：\n" +
                "1. X 在中国大陆无法直接访问，需要先开启网络加速工具；\n" +
                "2. 该推文已被删除、设为私密，或包含敏感内容。"
        )
    }

    private func extractStatusId(_ url: String) -> String? {
        if let m = WebPage.firstMatch(#"/(?:status|statuses)/(\d{10,25})"#, in: url) { return m }
        if let m = WebPage.firstMatch(#"[?&](?:id|status_id)=(\d{10,25})"#, in: url) { return m }
        return nil
    }

    private func fetchFromMirror(_ statusId: String) async -> [String: Any]? {
        for host in ["api.fxtwitter.com", "api.vxtwitter.com"] {
            guard let (data, http) = try? await UrlUtils.httpGet(
                "https://\(host)/status/\(statusId)", mobile: false, headers: headers
            ) else { continue }
            guard http.statusCode == 200 else { continue }
            guard let json = try? jsonObject(data), let tweet = obj(json, "tweet") else { continue }
            if str(tweet, "id_str").isEmpty && tweet["id"] == nil { continue }
            return tweet
        }
        return nil
    }

    /// X 官方的嵌入推文接口（无需登录，但只返回公开推文）
    private func fetchFromSyndication(_ statusId: String) async -> [String: Any]? {
        let token = syndicationToken(statusId)
        guard let (data, http) = try? await UrlUtils.httpGet(
            "https://cdn.syndication.twimg.com/tweet-result?id=\(statusId)&token=\(token)&lang=en",
            mobile: false, headers: headers
        ), http.statusCode == 200 else { return nil }
        guard let json = try? jsonObject(data) else { return nil }
        if str(json, "text").isEmpty && arr(json, "mediaDetails") == nil { return nil }
        return json
    }

    /// X 嵌入页用的小算法：((id / 1e15) * π) 的 36 进制表示，去掉 0 和小数点
    private func syndicationToken(_ statusId: String) -> String {
        let value = (Double(statusId) ?? 0) / 1e15 * Double.pi
        let intPart = Int64(value)
        var text = String(intPart, radix: 36)
        var fraction = value - Double(intPart)
        text += "."
        for _ in 0..<20 {
            fraction *= 36
            let digit = Int(fraction)
            text += String(digit, radix: 36)
            fraction -= Double(digit)
        }
        return text.replacingOccurrences(of: #"(0+|\.)"#, with: "", options: .regularExpression)
    }

    // MARK: - 结果组装

    private struct Media {
        let isVideo: Bool
        let isGif: Bool
        let url: String?
        let variants: [String]
    }

    private func buildResult(_ tweet: [String: Any], statusId: String) throws -> ParseResult {
        let author = str(obj(tweet, "author"), "screen_name").isEmpty
            ? str(obj(tweet, "user"), "screen_name")
            : str(obj(tweet, "author"), "screen_name")
        let caption = (str(tweet, "text").isEmpty ? str(tweet, "full_text") : str(tweet, "text"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var title = caption.components(separatedBy: "\n").first ?? ""
        if title.isEmpty { title = author.isEmpty ? "推文" : "@\(author) 的推文" }
        let safe = safeName(title, fallback: "tweet")
        var items: [MediaItem] = []

        let mediaList = collectMedia(tweet)
        let videoCount = mediaList.filter { $0.isVideo }.count
        var imageIndex = 0
        var videoIndex = 0
        for media in mediaList {
            if media.isVideo {
                var candidates = media.variants
                if candidates.isEmpty, let single = media.url { candidates = [single] }
                guard let first = candidates.first, let url = URL(string: first) else { continue }
                videoIndex += 1
                items.append(MediaItem(
                    id: "\(statusId)_video\(videoIndex)", kind: .video,
                    label: media.isGif ? "动图（GIF 转视频）" : "原视频",
                    fileName: videoCount > 1 ? "\(safe)_视频\(videoIndex).mp4" : "\(safe).mp4",
                    url: url, text: nil, altUrls: candidates.filter { $0 != first }
                ))
            } else {
                guard let raw = media.url, let url = URL(string: raw) else { continue }
                imageIndex += 1
                items.append(MediaItem(
                    id: "\(statusId)_img\(imageIndex)", kind: .image,
                    label: "原图 \(imageIndex)", fileName: "\(safe)_\(imageIndex).jpg",
                    url: url, text: nil
                ))
            }
        }

        if items.isEmpty && caption.isEmpty {
            throw ParseError("这条推文读不到内容，请确认链接是否有效")
        }

        items.append(MediaItem(
            id: "\(statusId)_cap", kind: .caption, label: "原文案",
            fileName: "\(safe)_文案.txt", url: nil, text: caption
        ))
        return ParseResult(platform: .x, title: title, author: author.isEmpty ? nil : author,
                           caption: caption, items: items)
    }

    /// 把两种接口的媒体结构统一成同一个列表
    private func collectMedia(_ tweet: [String: Any]) -> [Media] {
        var out: [Media] = []

        if let all = arr(obj(tweet, "media"), "all") {
            for raw in all {
                guard let m = raw as? [String: Any] else { continue }
                let type = str(m, "type").lowercased()
                let url = str(m, "url")
                if type == "photo" {
                    if !url.isEmpty { out.append(Media(isVideo: false, isGif: false, url: originalPhoto(url), variants: [])) }
                    continue
                }
                let variants = videoVariants(arr(m, "formats"))
                out.append(Media(isVideo: true, isGif: type == "gif",
                                 url: variants.first ?? (url.isEmpty ? nil : url), variants: variants))
            }
            if !out.isEmpty { return out }
        }

        if let details = arr(tweet, "mediaDetails") {
            for raw in details {
                guard let m = raw as? [String: Any] else { continue }
                let type = str(m, "type").lowercased()
                if type == "photo" {
                    let url = str(m, "media_url_https")
                    if !url.isEmpty {
                        out.append(Media(isVideo: false, isGif: false, url: originalPhoto(url), variants: []))
                    }
                } else {
                    let variants = videoVariants(arr(obj(m, "video_info"), "variants"))
                    if !variants.isEmpty {
                        out.append(Media(isVideo: true, isGif: false, url: variants.first, variants: variants))
                    }
                }
            }
            if !out.isEmpty { return out }
        }

        if let photos = arr(tweet, "photos") {
            for raw in photos {
                let url = str(raw as? [String: Any], "url")
                if !url.isEmpty {
                    out.append(Media(isVideo: false, isGif: false, url: originalPhoto(url), variants: []))
                }
            }
        }
        if let video = obj(tweet, "video") {
            let variants = videoVariants(arr(video, "variants"))
            if !variants.isEmpty {
                out.append(Media(isVideo: true, isGif: false, url: variants.first, variants: variants))
            }
        }
        return out
    }

    /// 取码率最高的 mp4；其他格式排在最后
    private func videoVariants(_ array: [Any]?) -> [String] {
        guard let array = array else { return [] }
        var mp4: [(Int, String)] = []
        var others: [String] = []
        for raw in array {
            guard let v = raw as? [String: Any] else { continue }
            var url = str(v, "url")
            if url.isEmpty { url = str(v, "src") }
            if url.isEmpty { continue }
            let type = str(v, "content_type").isEmpty ? str(v, "container") : str(v, "content_type")
            if type.contains("mp4") {
                mp4.append((int(v, "bitrate"), url))
            } else {
                others.append(url)
            }
        }
        return mp4.sorted { $0.0 > $1.0 }.map { $0.1 } + others
    }

    /// 图片统一取原图尺寸
    private func originalPhoto(_ url: String) -> String {
        guard url.contains("pbs.twimg.com") else { return url }
        let base = url.components(separatedBy: "?").first ?? url
        return base + "?name=orig"
    }
}

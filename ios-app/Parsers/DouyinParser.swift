import Foundation

struct DouyinParser {

    private let headers = [
        "Referer": "https://www.douyin.com/",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ]

    func parse(_ url: String) async throws -> ParseResult {
        let finalUrl = try await UrlUtils.resolveRedirect(url)
        guard let id = extractId(finalUrl) else {
            throw ParseError("未能在链接中找到抖音视频/图文ID")
        }
        // 旧接口优先（返回无水印地址）
        if let result = try? await parseOldApi(id) {
            return result
        }
        let html = try await fetchPage(finalUrl)
        if let result = try? parseRenderData(html) {
            return result
        }
        if let result = try? parseRouterData(html) {
            return result
        }
        if html.contains("captcha") || html.contains("验证码") || html.contains("安全验证") {
            throw ParseError("抖音返回了安全验证页，请稍后重试；或在抖音App中重新复制分享链接后再试")
        }
        throw ParseError("未能解析出内容，抖音页面结构可能已更新")
    }

    private func fetchPage(_ url: String) async throws -> String {
        let (data, resp) = try await UrlUtils.httpGet(url, headers: headers)
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else {
            throw ParseError("请求抖音失败 HTTP \(resp.statusCode)")
        }
        return s
    }

    private func parseRenderData(_ html: String) throws -> ParseResult? {
        guard let m = html.range(of: #"id="RENDER_DATA"[^>]*>(.*?)</script>"#, options: .regularExpression) else {
            return nil
        }
        let raw = String(html[m]).replacingOccurrences(of: #"id="RENDER_DATA"[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "</script>", with: "")
        guard let decoded = raw.removingPercentEncoding,
              let json = jsonObject(decoded),
              let app = obj(json, "app") else { return nil }
        if let vRes = obj(app, "videoInfoRes"),
           let list = arr(vRes, "item_list", "itemList"),
           let first = list.first as? [String: Any] {
            return try parseAweme(first)
        }
        if let nRes = obj(app, "noteDetailRes"),
           let detail = obj(nRes, "note_detail", "noteDetail"),
           let note = obj(detail, "note") {
            return try parseNote(note)
        }
        return nil
    }

    private func parseRouterData(_ html: String) throws -> ParseResult? {
        guard let m = html.range(of: #"window\._ROUTER_DATA\s*=\s*(\{.*?\})\s*</script>"#, options: .regularExpression) else {
            return nil
        }
        let raw = String(html[m])
        let start = raw.firstIndex(of: "{")!
        let jsonText = raw[start..<raw.index(raw.endIndex, offsetBy: -"</script>".count)]
        guard let json = jsonObject(String(jsonText)),
              let loader = obj(json, "loaderData") else { return nil }
        for (_, v) in loader {
            guard let o = v as? [String: Any],
                  let vRes = obj(o, "videoInfoRes"),
                  let list = arr(vRes, "item_list", "itemList"),
                  let first = list.first as? [String: Any] else { continue }
            return try parseAweme(first)
        }
        return nil
    }

    private func parseOldApi(_ id: String) async throws -> ParseResult? {
        let url = "https://www.iesdouyin.com/web/api/v2/aweme/iteminfo/?item_ids=\(id)"
        let (data, resp) = try await UrlUtils.httpGet(url, headers: headers)
        guard resp.statusCode == 200 else { return nil }
        let json = try jsonObject(data)
        guard let list = arr(json, "item_list", "itemList"), let first = list.first as? [String: Any] else {
            return nil
        }
        return try parseAweme(first)
    }

    private func parseAweme(_ item: [String: Any]) throws -> ParseResult {
        let desc = str(item, "desc").isEmpty ? "抖音内容" : str(item, "desc")
        let author = str(obj(item, "author"), "nickname")
        let awemeId = str(item, "aweme_id")
        var media: [MediaItem] = []

        if let video = obj(item, "video") {
            var seen = Set<String>()
            if let rates = arr(video, "bit_rate", "bitRate") {
                for (i, r) in rates.enumerated() {
                    guard let br = r as? [String: Any],
                          let u = firstUrl(obj(br, "play_addr")) else { continue }
                    let clean = stripWatermark(u)
                    guard seen.insert(clean).inserted else { continue }
                    let label = str(br, "gear_name").isEmpty ? "原视频" : str(br, "gear_name")
                    media.append(MediaItem(
                        id: "\(awemeId)_v\(i)", kind: .video,
                        label: "\(label)（无水印）", fileName: safeName(desc, fallback: "douyin") + ".mp4",
                        url: URL(string: clean), text: nil
                    ))
                }
            }
            if media.isEmpty, let u = firstUrl(obj(video, "play_addr")) {
                media.append(MediaItem(
                    id: "\(awemeId)_v", kind: .video,
                    label: "原视频（无水印）", fileName: safeName(desc, fallback: "douyin") + ".mp4",
                    url: URL(string: stripWatermark(u)), text: nil
                ))
            }
        }

        if let images = arr(item, "images") {
            for (i, img) in images.enumerated() {
                guard let im = img as? [String: Any],
                      let u = firstUrl(obj(im, "download_url_list", "downloadUrlList"))
                        ?? firstUrl(obj(im, "url_list", "urlList")) else { continue }
                media.append(MediaItem(
                    id: "\(awemeId)_img\(i)", kind: .image,
                    label: "原图 \(i + 1)", fileName: safeName(desc, fallback: "douyin") + "_\(i + 1).jpg",
                    url: URL(string: u), text: nil
                ))
            }
        }

        guard !media.isEmpty else {
            throw ParseError("未找到可下载的视频或图片")
        }
        return ParseResult(platform: .douyin, title: desc, author: author, caption: desc, items: media)
    }

    private func parseNote(_ note: [String: Any]) throws -> ParseResult {
        let desc = str(note, "desc").isEmpty
            ? (str(note, "title").isEmpty ? "抖音图文" : str(note, "title"))
            : str(note, "desc")
        let author = str(obj(note, "author"), "nickname")
        let noteId = str(note, "note_id").isEmpty ? "note" : str(note, "note_id")
        var media: [MediaItem] = []
        let images = arr(note, "imagesList", "images", "imageList") ?? []
        for (i, img) in images.enumerated() {
            guard let im = img as? [String: Any],
                  let u = firstUrl(obj(im, "urlList", "url_list"))
                    ?? firstUrl(obj(im, "downloadUrlList", "download_url_list")) else { continue }
            media.append(MediaItem(
                id: "\(noteId)_img\(i)", kind: .image,
                label: "原图 \(i + 1)", fileName: safeName(desc, fallback: "douyin") + "_\(i + 1).jpg",
                url: URL(string: u), text: nil
            ))
        }
        guard !media.isEmpty else { throw ParseError("未找到图文内容") }
        return ParseResult(platform: .douyin, title: desc, author: author, caption: desc, items: media)
    }

    private func firstUrl(_ o: [String: Any]?) -> String? {
        guard let list = arr(o, "url_list", "urlList"), let first = list.first as? String else { return nil }
        return first
    }

    private func stripWatermark(_ u: String) -> String {
        u.replacingOccurrences(of: "playwm", with: "play")
    }

    private func extractId(_ url: String) -> String? {
        let patterns = [
            #"/(?:video|note)/(\d+)"#,
            #"/(?:share/video|share/note)/(\d+)"#,
            #"item_ids=(\d+)"#,
            #"modal_id=(\d+)"#,
        ]
        for p in patterns {
            if let m = url.range(of: p, options: .regularExpression) {
                let s = String(url[m])
                if let digits = s.range(of: #"\d+"#, options: .regularExpression) {
                    return String(s[digits])
                }
            }
        }
        return nil
    }
}

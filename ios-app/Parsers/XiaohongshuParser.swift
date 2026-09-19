import Foundation
import WebKit

/// 小红书解析器。
///
/// 关键结论（与安卓版一致，2026-09 实测）：
/// 1. 手机版笔记页 /discovery/item/<笔记ID>?xsec_token=...&xsec_source=... 会把整条笔记
///    内联进页面 JSON（window.__SETUP_SERVER_STATE__ / window.__INITIAL_STATE__），
///    标题、正文、全部原图、无水印原视频都能读到，不需要登录。
/// 2. 桌面版 /explore/<笔记ID> 带 token 时经常被重定向到登录页，只作备用。
/// 3. xsec_token 是关键：短链必须逐跳解析，任何一跳里的参数都不能丢。
struct XiaohongshuParser {

    private struct Share {
        let noteId: String
        let pageUrl: String
        let token: String?
        let source: String
    }

    private let hosts = [
        "sns-video-bd.xhscdn.com",
        "sns-video-al.xhscdn.com",
        "sns-video-hw.xhscdn.com",
        "sns-video-qc.xhscdn.com",
    ]

    private let headers = [
        "Referer": "https://www.xiaohongshu.com/",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Cache-Control": "no-cache",
        "Upgrade-Insecure-Requests": "1",
    ]

    private let markers = [
        "window.__SETUP_SERVER_STATE__",
        "window.__INITIAL_STATE__",
    ]

    func parse(_ url: String) async throws -> ParseResult {
        let share = try await resolveShare(url)

        // 通道一（实测最稳）：手机版笔记页 + xsec_token
        var note = await fetchMobileNote(share)

        // 通道二：桌面版页面里的 window.__INITIAL_STATE__
        if note == nil {
            for page in desktopPages(share) {
                if let n = await fetchDesktopNote(page, noteId: share.noteId) {
                    note = n
                    break
                }
            }
        }

        // 通道三/四：真实 WKWebView 加载页面（拿到风控 Cookie 后再取一次），最后直接读页面 JS 状态
        if note == nil {
            if let a = await fetchMobileNote(share) { note = a }
        }
        if note == nil {
            for page in desktopPages(share) {
                if let n = await fetchDesktopNote(page, noteId: share.noteId) {
                    note = n
                    break
                }
            }
        }
        if note == nil {
            note = await fetchNoteViaWebView(share)
        }

        guard let found = note else {
            throw ParseError(explainFailure(share))
        }
        return try buildResult(found, noteId: share.noteId)
    }

    // MARK: - 链接解析

    private func resolveShare(_ url: String) async throws -> Share {
        var chains: [[String]] = []
        chains.append(await UrlUtils.resolveRedirectChain(url, mobile: false))
        chains.append(await UrlUtils.resolveRedirectChain(url, mobile: true))

        for chain in chains {
            for candidate in chain {
                guard let noteId = Self.extractNoteId(candidate) else { continue }
                let token = queryParam(candidate, "xsec_token") ?? queryParam(url, "xsec_token")
                let source = queryParam(candidate, "xsec_source")
                    ?? queryParam(url, "xsec_source")
                    ?? "pc_share"
                return Share(noteId: noteId, pageUrl: pageUrl(noteId: noteId, token: token, source: source),
                             token: token, source: source)
            }
        }
        guard let noteId = Self.extractNoteId(url) else {
            throw ParseError("未能在链接中找到小红书笔记ID，请确认分享链接完整有效")
        }
        let token = queryParam(url, "xsec_token")
        let source = queryParam(url, "xsec_source") ?? "pc_share"
        return Share(noteId: noteId, pageUrl: pageUrl(noteId: noteId, token: token, source: source),
                     token: token, source: source)
    }

    static func extractNoteId(_ url: String) -> String? {
        if let m = WebPage.firstMatch(#"/(?:discovery/item|explore|notes|item)/([0-9a-fA-F]{24})"#, in: url) {
            return m
        }
        if let m = WebPage.firstMatch(#"[?&](?:noteId|note_id|id)=([0-9a-fA-F]{24})"#, in: url) {
            return m
        }
        return nil
    }

    private func queryParam(_ url: String, _ name: String) -> String? {
        guard let v = WebPage.firstMatch("[?&]" + NSRegularExpression.escapedPattern(for: name) + "=([^&#]*)",
                                         in: url) else { return nil }
        return v.isEmpty ? nil : v
    }

    private func pageUrl(noteId: String, token: String?, source: String) -> String {
        var s = "https://www.xiaohongshu.com/explore/\(noteId)"
        if let token = token, !token.isEmpty {
            s += "?xsec_token=\(token)&xsec_source=\(source)"
        }
        return s
    }

    private func mobileUrl(_ share: Share) -> String {
        var s = "https://www.xiaohongshu.com/discovery/item/\(share.noteId)"
        if let token = share.token, !token.isEmpty {
            s += "?xsec_token=\(token)&xsec_source=\(share.source)"
        }
        return s
    }

    private func desktopPages(_ share: Share) -> [String] {
        var out: [String] = [share.pageUrl]
        if let token = share.token, !token.isEmpty {
            out.append("https://www.xiaohongshu.com/discovery/item/\(share.noteId)?xsec_token=\(token)&xsec_source=\(share.source)")
            out.append("https://www.xiaohongshu.com/explore/\(share.noteId)?xsec_token=\(token)&xsec_source=pc_note_detail")
        }
        out.append("https://www.xiaohongshu.com/discovery/item/\(share.noteId)")
        out.append("https://www.xiaohongshu.com/explore/\(share.noteId)")
        var unique: [String] = []
        for u in out where !unique.contains(u) { unique.append(u) }
        return unique
    }

    // MARK: - 取数

    private func fetchMobileNote(_ share: Share) async -> [String: Any]? {
        let url = mobileUrl(share)
        guard let (data, _) = try? await UrlUtils.httpGet(
            url, mobile: true, referer: "https://www.xiaohongshu.com/", headers: headers
        ) else { return nil }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return parseMobileHtml(html, noteId: share.noteId)
    }

    private func fetchDesktopNote(_ url: String, noteId: String) async -> [String: Any]? {
        guard let (data, _) = try? await UrlUtils.httpGet(
            url, mobile: false, referer: "https://www.xiaohongshu.com/", headers: headers
        ) else { return nil }
        guard let html = String(data: data, encoding: .utf8), html.contains("noteDetailMap") else { return nil }
        guard let state = WebPage.assignedJson(html, marker: "window.__INITIAL_STATE__")
            ?? WebPage.assignedJson(html, marker: "__INITIAL_STATE__") else { return nil }
        guard let map = noteDetailMap(state) else { return nil }
        if let ent = map[noteId] as? [String: Any] {
            let n = (ent["note"] as? [String: Any]) ?? ent
            if WebPage.looksLikeNote(n) { return n }
        }
        for (_, value) in map {
            guard let ent = value as? [String: Any] else { continue }
            let n = (ent["note"] as? [String: Any]) ?? ent
            if WebPage.looksLikeNote(n), WebPage.hasSubstance(n) { return n }
        }
        return nil
    }

    private func noteDetailMap(_ state: [String: Any]) -> [String: Any]? {
        if let note = state["note"] as? [String: Any],
           let map = note["noteDetailMap"] as? [String: Any] {
            return map
        }
        for (_, value) in state {
            if let dict = value as? [String: Any],
               let map = dict["noteDetailMap"] as? [String: Any] {
                return map
            }
        }
        return nil
    }

    /// 手机版页面：先读内联 JSON，读不到再退回 DOM 抓取
    private func parseMobileHtml(_ html: String, noteId: String) -> [String: Any]? {
        if html.isEmpty || !html.contains(noteId) { return nil }
        for marker in markers {
            if let root = WebPage.assignedJson(html, marker: marker),
               let note = WebPage.findNote(root, noteId: noteId) {
                return note
            }
        }

        // DOM 兜底
        var fileIds: [String] = []
        for src in WebPage.allMatches(#"<img[^>]*\bsrc="([^"]+)""#, in: html) {
            guard src.contains("xhscdn"), !src.contains("/avatar/") else { continue }
            guard src.contains("sns-webpic") || src.contains("sns-img") else { continue }
            if let fid = WebPage.firstMatch(#"/(notes_uhdr/[A-Za-z0-9_\-]+)"#, in: src),
               !fileIds.contains(fid) {
                fileIds.append(fid)
            }
        }
        let videos = extractMobileVideos(html)
        if fileIds.isEmpty && videos.isEmpty { return nil }

        var note: [String: Any] = ["noteId": noteId, "desc": extractMobileDesc(html)]
        note["imageList"] = fileIds.map { ["fileId": $0] }
        if !videos.isEmpty {
            note["video"] = ["mobileUrls": videos]
        }
        return note
    }

    /// 手机版页面里的视频地址是 JSON 转义写法，先还原再按码率排序（h264 优先）
    private func extractMobileVideos(_ html: String) -> [String] {
        let text = WebPage.normalizeEscapes(html)
        let nsText = text as NSString
        let h264Loc = nsText.range(of: "\"h264\":[").location
        let h265Loc = nsText.range(of: "\"h265\":[").location

        var preferred: [(Int, String)] = []
        var fallback: [(Int, String)] = []

        let regex = try? NSRegularExpression(pattern: #""masterUrl":"(https?://[^"]+?)""#)
        if let regex = regex {
            for m in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                guard m.numberOfRanges > 1 else { continue }
                let url = nsText.substring(with: m.range(at: 1))
                let tailStart = m.range.location + m.range.length
                let tailLength = min(700, max(0, nsText.length - tailStart))
                let tail = tailLength > 0 ? nsText.substring(with: NSRange(location: tailStart, length: tailLength)) : ""
                let bitrate = Int(WebPage.firstMatch(#""avgBitrate":(\d+)"#, in: tail) ?? "0") ?? 0
                var inH264 = false
                if h265Loc != NSNotFound {
                    if h264Loc != NSNotFound {
                        inH264 = m.range.location > h264Loc && m.range.location < h265Loc
                    }
                } else if h264Loc != NSNotFound {
                    inH264 = m.range.location > h264Loc
                }
                if inH264 { preferred.append((bitrate, url)) } else { fallback.append((bitrate, url)) }
            }
        }

        var ordered: [String] = []
        let primary = preferred.isEmpty ? fallback : preferred
        for item in primary.sorted(by: { $0.0 > $1.0 }) where !ordered.contains(item.1) {
            ordered.append(item.1)
        }
        for item in fallback.sorted(by: { $0.0 > $1.0 }) where !ordered.contains(item.1) {
            ordered.append(item.1)
        }
        for url in WebPage.allMatches(#"https?://[^"'\s\\]+\.(?:mp4|m3u8)[^"'\s\\]*"#, in: text, group: 0)
        where url.contains("xhscdn") && !ordered.contains(url) {
            ordered.append(url)
        }
        return ordered
    }

    private func extractMobileDesc(_ html: String) -> String {
        guard let r = html.range(of: "author-desc-content") else { return "" }
        let tail = String(html[r.upperBound...].prefix(8000))
        let spans = WebPage.allMatches(#"<span[^>]*>([^<]{1,400})</span>"#, in: tail)
        return WebPage.unescapeHtml(spans.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - WKWebView 兜底

    @MainActor
    private func fetchNoteViaWebView(_ share: Share) async -> [String: Any]? {
        let js = Self.extractJs.replacingOccurrences(of: "MY_NOTE_ID", with: share.noteId)
        let pages = [mobileUrl(share), share.pageUrl]
        for page in pages {
            let raw = await HiddenWebView.shared.loadAndExtract(
                url: page,
                userAgent: page.contains("/discovery/item/") ? UrlUtils.UA.mobile : UrlUtils.UA.desktop,
                js: js
            )
            if let raw = raw, let obj = jsonObject(raw),
               let note = obj["note"] as? [String: Any],
               WebPage.looksLikeNote(note) {
                return note
            }
        }
        return nil
    }

    private static let extractJs = """
    (function(){
      try {
        var nid = "MY_NOTE_ID";
        function walk(node, depth) {
          if (!node || typeof node !== 'object' || depth > 20) return null;
          if (Object.prototype.toString.call(node) === '[object Array]') {
            for (var i = 0; i < node.length; i++) {
              var hit = walk(node[i], depth + 1);
              if (hit) return hit;
            }
            return null;
          }
          var hasContent = (node.imageList && node.imageList.length) ||
                           (node.video && Object.keys(node.video).length) ||
                           (node.desc && String(node.desc).length) ||
                           (node.title && String(node.title).length);
          var idOk = true;
          if (node.noteId && typeof node.noteId === 'string' && node.noteId.length === 24) {
            idOk = (node.noteId === nid);
          }
          if (hasContent && idOk && (node.noteId || node.desc)) return node;
          for (var k in node) {
            if (!Object.prototype.hasOwnProperty.call(node, k)) continue;
            var hit2 = walk(node[k], depth + 1);
            if (hit2) return hit2;
          }
          return null;
        }
        var roots = [];
        if (window.__SETUP_SERVER_STATE__) roots.push(window.__SETUP_SERVER_STATE__);
        if (window.__INITIAL_STATE__) roots.push(window.__INITIAL_STATE__);
        var scripts = document.querySelectorAll('script');
        for (var s = 0; s < scripts.length; s++) {
          var t = scripts[s].textContent || '';
          if (t.length < 200) continue;
          if (t.indexOf('imageList') < 0 && t.indexOf('noteId') < 0) continue;
          try { roots.push(JSON.parse(t)); } catch (e) {}
        }
        for (var r = 0; r < roots.length; r++) {
          var note = walk(roots[r], 0);
          if (note) return JSON.stringify({ok: true, note: note});
        }
        return "";
      } catch (e) { return ""; }
    })()
    """

    // MARK: - 结果组装

    private func buildResult(_ note: [String: Any], noteId: String) throws -> ParseResult {
        let desc = str(note, "desc").isEmpty ? str(note, "title") : str(note, "desc")
        var title = str(note, "title")
        if title.isEmpty { title = desc.components(separatedBy: "\n").first ?? "小红书笔记" }
        if title.isEmpty { title = "小红书笔记" }
        let author = str(obj(note, "user"), "nickname")
        let safe = safeName(title, fallback: "xiaohongshu")
        var items: [MediaItem] = []

        if let images = arr(note, "imageList", "image_list") {
            for (i, raw) in images.enumerated() {
                guard let image = raw as? [String: Any] else { continue }
                let candidates = imageCandidates(image)
                guard let first = candidates.first, let url = URL(string: first) else { continue }
                items.append(MediaItem(
                    id: "\(noteId)_img\(i)", kind: .image,
                    label: "原图 \(i + 1)", fileName: "\(safe)_\(i + 1).jpg",
                    url: url, text: nil, altUrls: Array(candidates.dropFirst())
                ))
            }
        }

        if let video = obj(note, "video") {
            let candidates = videoCandidates(video)
            if let first = candidates.first, let url = URL(string: first) {
                items.append(MediaItem(
                    id: "\(noteId)_video", kind: .video,
                    label: first.lowercased().contains(".m3u8") ? "原视频（无水印 HLS）" : "原视频（无水印）",
                    fileName: "\(safe).mp4", url: url, text: nil,
                    altUrls: candidates.filter { $0 != first }
                ))
            }
        }

        var caption = desc
        if let tags = arr(note, "tagList"), !tags.isEmpty {
            var tagText = ""
            for tag in tags {
                let name = str(tag as? [String: Any], "name")
                if !name.isEmpty { tagText += "#\(name) " }
            }
            if !tagText.isEmpty { caption += "\n\n\(tagText)" }
        }

        if items.isEmpty && caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ParseError("这条笔记读不到内容，请确认链接是否完整有效")
        }

        items.append(MediaItem(
            id: "\(noteId)_cap", kind: .caption,
            label: "原文案", fileName: "\(safe)_文案.txt",
            url: nil, text: caption
        ))
        return ParseResult(platform: .xiaohongshu, title: title, author: author, caption: caption, items: items)
    }

    /// 图片地址优先级：sns-img-bd + fileId（原图，HDR 图加参数转 JPEG）→ 官方默认图 → 备选图
    private func imageCandidates(_ image: [String: Any]) -> [String] {
        var out: [String] = []
        var fileId = str(image, "fileId", "file_id").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if fileId.isEmpty {
            let fallback = fixUrl(str(image, "urlDefault", "url_default", "url"))
            if let parsed = WebPage.firstMatch(#"/(notes_uhdr/[A-Za-z0-9_\-]+)"#, in: fallback) {
                fileId = parsed
            }
        }
        if !fileId.isEmpty {
            let base = "https://sns-img-bd.xhscdn.com/" + fileId
            let isHdr = fileId.lowercased().contains("uhdr") || fileId.lowercased().contains("heic")
            if isHdr {
                out.append(base + "?imageView2/2/format/jpg")
            } else {
                out.append(base)
                out.append(base + "?imageView2/2/format/jpg")
            }
        }
        let defaults = [
            fixUrl(str(image, "urlDefault", "url_default")),
            fixUrl(str(image, "url")),
        ]
        for url in defaults where !url.isEmpty && !out.contains(url) { out.append(url) }
        if let infoList = arr(image, "infoList") {
            for info in infoList {
                let url = fixUrl(str(info as? [String: Any], "url"))
                if !url.isEmpty && !out.contains(url) { out.append(url) }
            }
        }
        return out
    }

    /// 视频地址优先级：原视频 key（无水印）→ 直链 → 手机版地址 → 各清晰度转码流
    private func videoCandidates(_ video: [String: Any]) -> [String] {
        var out: [String] = []
        let originKey = str(obj(video, "consumer"), "originVideoKey", "origin_video_key")
        if !originKey.isEmpty {
            let key = originKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for host in hosts { out.append("https://\(host)/\(key)") }
        }
        let direct = fixUrl(str(video, "url"))
        if !direct.isEmpty { out.append(direct) }
        if let mobile = arr(video, "mobileUrls") {
            for raw in mobile {
                let url = fixUrl(raw as? String ?? "")
                if !url.isEmpty && !out.contains(url) { out.append(url) }
            }
        }
        if let stream = obj(obj(video, "media"), "stream") {
            for codec in ["h264", "h265", "av1"] {
                guard let list = arr(stream, codec) else { continue }
                var scored: [(Int, String)] = []
                for raw in list {
                    guard let item = raw as? [String: Any] else { continue }
                    let master = fixUrl(str(item, "masterUrl", "master_url"))
                    if !master.isEmpty { scored.append((int(item, "avgBitrate"), master)) }
                }
                for pair in scored.sorted(by: { $0.0 > $1.0 }) where !out.contains(pair.1) {
                    out.append(pair.1)
                }
                for raw in list {
                    guard let item = raw as? [String: Any] else { continue }
                    if let backups = arr(item, "backupUrls", "backup_urls") {
                        for b in backups {
                            let url = fixUrl(b as? String ?? "")
                            if !url.isEmpty && !out.contains(url) { out.append(url) }
                        }
                    }
                }
            }
        }
        return out
    }

    private func explainFailure(_ share: Share) -> String {
        var text = "无法读取小红书笔记。\n\n"
        if share.token == nil {
            text += "原因：链接里缺少必要的 xsec_token 参数。\n"
            text += "解决：请在小红书 App 里点【分享 → 复制链接】，把整段分享文字粘贴进来，"
            text += "不要只复制浏览器地址栏里的短地址。\n"
        } else {
            text += "原因：页面返回了登录/风控拦截页（短时间解析次数太多时会这样）。\n"
            text += "解决：等 10 分钟后重试，或先在手机上打开小红书 App 登录一次再回来解析。\n"
        }
        text += "\n当前链接：\(share.pageUrl.prefix(120))"
        return text
    }
}

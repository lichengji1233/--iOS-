import Foundation
import WebKit

/// Instagram 解析器。
///
/// Instagram 没有公开的免登录接口，这里按成功率依次尝试：
/// 1. /api/v1/media/<媒体ID>/info/
/// 2. /p/<短码>/?__a=1&__d=dis
/// 3. 帖子嵌入页里内联的 JSON（contextJSON）
/// 4. 隐藏 WKWebView 真实渲染后读页面里的内联 JSON / DOM（最接近"人工打开帖子"）
///
/// 注意：Instagram 在中国大陆无法直接访问，需要网络加速工具。
struct InstagramParser {

    private let appId = "936619743392459"
    private let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private var headers: [String: String] {
        [
            "X-IG-App-ID": appId,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://www.instagram.com/",
        ]
    }

    func parse(_ url: String) async throws -> ParseResult {
        let chain = await UrlUtils.resolveRedirectChain(url, mobile: true)
        var code: String?
        for candidate in chain.reversed() {
            if let found = extractShortcode(candidate) {
                code = found
                break
            }
        }
        guard let shortcode = code else {
            throw ParseError("未能在链接中找到 Instagram 帖子编号，请确认链接完整")
        }

        if let media = await fetchFromApi(shortcodeToId(shortcode)) {
            return try buildResult(media, code: shortcode)
        }
        if let media = await fetchFromPostJson(shortcode) {
            return try buildResult(media, code: shortcode)
        }
        if let media = await fetchFromEmbed(shortcode) {
            return try buildResult(media, code: shortcode)
        }
        if let media = await fetchFromWebView(shortcode) {
            return try buildResult(media, code: shortcode)
        }
        throw ParseError(
            "无法获取 Instagram 内容。\n\n常见原因：\n" +
                "1. Instagram 在中国大陆无法直接访问，需要先开启网络加速工具；\n" +
                "2. 该帖子属于私密账号、已被删除，或需要登录才能查看；\n" +
                "3. 同一时间解析过于频繁，被 Instagram 限流，稍后再试。"
        )
    }

    private func extractShortcode(_ url: String) -> String? {
        if let m = WebPage.firstMatch(#"/(?:p|reel|reels|tv|share)/([A-Za-z0-9_\-]{5,20})"#, in: url) {
            return m
        }
        if let m = WebPage.firstMatch(#"[?&](?:shortcode|code)=([A-Za-z0-9_\-]{5,20})"#, in: url) {
            return m
        }
        return nil
    }

    /// 短码是媒体数字 ID 的 64 进制表示，部分接口需要数字 ID
    private func shortcodeToId(_ code: String) -> String {
        var value: Int64 = 0
        for ch in code {
            guard let digit = alphabet.firstIndex(of: ch) else { return code }
            let (multiplied, overflow) = value.multipliedReportingOverflow(by: 64)
            if overflow { return code }
            let (sum, overflow2) = multiplied.addingReportingOverflow(Int64(digit))
            if overflow2 { return code }
            value = sum
        }
        return String(value)
    }

    // MARK: - 多种取数方式

    private func fetchFromApi(_ mediaId: String) async -> [String: Any]? {
        guard let (data, http) = try? await UrlUtils.httpGet(
            "https://www.instagram.com/api/v1/media/\(mediaId)/info/",
            mobile: true, headers: headers
        ), http.statusCode == 200 else { return nil }
        guard let json = try? jsonObject(data), let items = arr(json, "items") else { return nil }
        return items.first as? [String: Any]
    }

    private func fetchFromPostJson(_ code: String) async -> [String: Any]? {
        guard let (data, http) = try? await UrlUtils.httpGet(
            "https://www.instagram.com/p/\(code)/?__a=1&__d=dis",
            mobile: true, headers: headers
        ), http.statusCode == 200 else { return nil }
        guard let json = try? jsonObject(data) else { return nil }
        if let items = arr(json, "items"), let first = items.first as? [String: Any] { return first }
        if let graphql = obj(json, "graphql") { return obj(graphql, "shortcode_media") }
        if let payload = obj(json, "data") { return obj(payload, "xdt_shortcode_media") }
        return nil
    }

    /// 嵌入页的 HTML 里偶尔内联了帖子 JSON（contextJSON 里的 gql_data）
    private func fetchFromEmbed(_ code: String) async -> [String: Any]? {
        guard let (data, _) = try? await UrlUtils.httpGet(
            "https://www.instagram.com/p/\(code)/embed/captioned/",
            mobile: true, headers: headers
        ), let html = String(data: data, encoding: .utf8) else { return nil }

        var searchStart = html.startIndex
        while let r = html.range(of: "\"contextJSON\":", range: searchStart..<html.endIndex) {
            searchStart = r.upperBound
            var p = r.upperBound
            while p < html.endIndex, html[p] != "{" { p = html.index(after: p) }
            guard p < html.endIndex, let end = WebPage.matchBrace(html, from: p) else { continue }
            let raw = String(html[p...end])
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\/", with: "/")
            guard let ctx = jsonObject(raw) else { continue }
            if let gql = obj(ctx, "gql_data"), let media = obj(gql, "shortcode_media") { return media }
            if let nested = obj(obj(ctx, "context"), "gql_data"),
               let media = obj(nested, "shortcode_media") {
                return media
            }
        }
        return nil
    }

    // MARK: - WKWebView 兜底

    @MainActor
    private func fetchFromWebView(_ code: String) async -> [String: Any]? {
        let js = Self.pageExtractJs
            .replacingOccurrences(of: "MY_CODE", with: code)
            .replacingOccurrences(of: "MY_MEDIA_ID", with: shortcodeToId(code))
        let pages = [
            "https://www.instagram.com/p/\(code)/",
            "https://www.instagram.com/p/\(code)/embed/captioned/",
        ]
        for page in pages {
            guard let raw = await HiddenWebView.shared.loadAndExtract(
                url: page, userAgent: UrlUtils.UA.mobile, js: js
            ) else { continue }
            if let media = buildMediaFromWebView(raw) { return media }
        }
        return nil
    }

    private func buildMediaFromWebView(_ raw: String) -> [String: Any]? {
        guard let obj = jsonObject(raw) else { return nil }
        var media: [String: Any] = [:]
        let caption = str(obj, "caption")
        if !caption.isEmpty { media["caption"] = ["text": caption] }
        let username = str(obj, "username")
        if !username.isEmpty { media["user"] = ["username": username] }

        var parts: [[String: Any]] = []
        if let list = arr(obj, "parts") {
            for raw in list {
                if let part = raw as? [String: Any] { parts.append(part) }
            }
        }
        if parts.isEmpty {
            guard let single = partFromArrays(arr(obj, "videos"), arr(obj, "images")) else { return nil }
            parts.append(single)
        }
        if parts.count == 1 {
            for (k, v) in parts[0] { media[k] = v }
        } else {
            media["carousel_media"] = parts
        }
        let ok = media["video_versions"] != nil || media["image_versions2"] != nil ||
            media["carousel_media"] != nil
        return ok ? media : nil
    }

    private func partFromArrays(_ videos: [Any]?, _ images: [Any]?) -> [String: Any]? {
        var part: [String: Any] = [:]
        var videoCount = 0
        if let videos = videos, !videos.isEmpty {
            let list = videos.compactMap { $0 as? [String: Any] }
            if !list.isEmpty {
                part["media_type"] = 2
                part["video_versions"] = list
                videoCount = list.count
            }
        }
        if videoCount == 0, let images = images, !images.isEmpty {
            let list = images.compactMap { $0 as? [String: Any] }
            if !list.isEmpty {
                part["media_type"] = 1
                part["image_versions2"] = ["candidates": list]
            }
        }
        return part["video_versions"] != nil || part["image_versions2"] != nil ? part : nil
    }

    private static let pageExtractJs = """
    (function(){
      try {
        var wantId = "MY_MEDIA_ID";
        var wantCode = "MY_CODE";
        var res = {parts: [], videos: [], images: [], caption: "", username: "", source: ""};

        function norm(m) {
          if (!m || typeof m !== 'object') return null;
          var out = null;
          var vv = m.video_versions;
          if (vv && vv.length) {
            out = out || {media_type: 2};
            out.video_versions = [];
            for (var i = 0; i < vv.length; i++) {
              if (vv[i] && vv[i].url) {
                out.video_versions.push({url: vv[i].url, width: vv[i].width || 0, height: vv[i].height || 0});
              }
            }
          }
          var iv = m.image_versions2 && m.image_versions2.candidates;
          if (!iv && m.display_resources) iv = m.display_resources;
          if (iv && iv.length) {
            out = out || {media_type: 1};
            out.image_versions2 = {candidates: []};
            for (var j = 0; j < iv.length; j++) {
              if (iv[j] && iv[j].url) {
                out.image_versions2.candidates.push({url: iv[j].url, width: iv[j].width || 0, height: iv[j].height || 0});
              }
            }
          }
          if (!out && m.display_url) {
            out = {media_type: 1, image_versions2: {candidates: [
              {url: m.display_url, width: m.original_width || 0, height: m.original_height || 0}
            ]}};
          }
          return out;
        }

        function captionOf(m) {
          var c = m.caption;
          if (c && c.text) return c.text;
          if (typeof c === 'string') return c;
          var e = m.edge_media_to_caption && m.edge_media_to_caption.edges;
          if (e && e.length && e[0].node && e[0].node.text) return e[0].node.text;
          return "";
        }

        function userOf(m) {
          var u = m.user || m.owner;
          return (u && u.username) ? u.username : "";
        }

        var best = null;
        var bestScore = -1;

        function consider(m) {
          if (!norm(m)) return;
          var id = String(m.pk || m.id || m.media_id || "");
          var cd = String(m.code || m.shortcode || "");
          var score = 0;
          if (wantId && id === wantId) score = 100;
          else if (cd && cd === wantCode) score = 100;
          if (score > bestScore) { bestScore = score; best = m; }
        }

        function walk(node, depth) {
          if (!node || typeof node !== 'object' || depth > 14) return;
          if (Object.prototype.toString.call(node) === '[object Array]') {
            for (var i = 0; i < node.length && i < 80; i++) walk(node[i], depth + 1);
            return;
          }
          consider(node);
          for (var k in node) {
            if (Object.prototype.hasOwnProperty.call(node, k)) walk(node[k], depth + 1);
          }
        }

        var scripts = document.querySelectorAll('script');
        for (var s = 0; s < scripts.length; s++) {
          var txt = scripts[s].textContent || "";
          if (txt.length < 80) continue;
          if (txt.indexOf('image_versions2') < 0 && txt.indexOf('video_versions') < 0
              && txt.indexOf('display_url') < 0) continue;
          try { walk(JSON.parse(txt), 0); } catch (e) {}
        }
        try { if (window.__additionalDataLoaded) walk(window.__additionalDataLoaded, 0); } catch (e) {}

        if (best) {
          res.source = 'ssr';
          res.caption = captionOf(best);
          res.username = userOf(best);
          var kids = best.carousel_media;
          if (!kids && best.edge_sidecar_to_children) kids = best.edge_sidecar_to_children.edges;
          if (kids && kids.length) {
            for (var k2 = 0; k2 < kids.length; k2++) {
              var n2 = (kids[k2] && kids[k2].node) ? kids[k2].node : kids[k2];
              var nn = norm(n2);
              if (nn) res.parts.push(nn);
            }
          }
          if (!res.parts.length) {
            var solo = norm(best);
            if (solo) res.parts.push(solo);
          }
        }

        if (!res.parts.length) {
          res.source = 'dom';
          var vids = document.querySelectorAll('video');
          for (var a = 0; a < vids.length; a++) {
            var vs = vids[a].src;
            if (!vs && vids[a].querySelector('source')) vs = vids[a].querySelector('source').src;
            if (vs && vs.indexOf('http') === 0) res.videos.push({url: vs, width: 0, height: 0});
          }
          var imgs = document.querySelectorAll('img');
          for (var b = 0; b < imgs.length; b++) {
            var u = imgs[b].src || "";
            if (u.indexOf('cdninstagram') < 0 && u.indexOf('fbcdn') < 0) continue;
            if (u.indexOf('s150x150') >= 0 || u.indexOf('s320x320') >= 0) continue;
            if (imgs[b].naturalWidth && imgs[b].naturalWidth < 300) continue;
            res.images.push({url: u, width: imgs[b].naturalWidth || 0, height: imgs[b].naturalHeight || 0});
          }
          var cap = document.querySelector('h1') || document.querySelector('.Caption');
          if (cap) res.caption = (cap.innerText || "").slice(0, 2000);
          if (!res.caption) {
            var meta = document.querySelector('meta[property="og:description"]');
            if (meta) res.caption = meta.getAttribute('content') || "";
          }
        }

        if (!res.parts.length && !res.videos.length && !res.images.length) return "";
        return JSON.stringify(res);
      } catch (e) { return ""; }
    })()
    """

    // MARK: - 结果组装

    private func buildResult(_ media: [String: Any], code: String) throws -> ParseResult {
        let caption = str(obj(media, "caption"), "text").trimmingCharacters(in: .whitespacesAndNewlines)
        var author = str(obj(media, "user"), "username")
        if author.isEmpty { author = str(obj(media, "owner"), "username") }
        var title = caption.components(separatedBy: "\n").first ?? ""
        if title.isEmpty { title = author.isEmpty ? "Instagram 帖子" : "@\(author) 的帖子" }
        let safe = safeName(title, fallback: "instagram")
        var items: [MediaItem] = []

        var parts: [[String: Any]] = []
        if let carousel = arr(media, "carousel_media") {
            parts = carousel.compactMap { $0 as? [String: Any] }
        } else if let edges = arr(media, "edge_sidecar_to_children") {
            parts = edges.compactMap { ($0 as? [String: Any]).flatMap { obj($0, "node") } }
        } else {
            parts = [media]
        }

        var imageIndex = 0
        var videoIndex = 0
        for part in parts {
            let isVideo = int(part, "media_type") == 2 || (part["is_video"] as? Bool == true) ||
                part["video_versions"] != nil || !str(part, "video_url").isEmpty
            if isVideo {
                let candidates = videoCandidates(part)
                guard let first = candidates.first, let url = URL(string: first) else { continue }
                videoIndex += 1
                items.append(MediaItem(
                    id: "\(code)_video\(videoIndex)", kind: .video,
                    label: parts.count > 1 ? "原视频 \(videoIndex)" : "原视频",
                    fileName: parts.count > 1 ? "\(safe)_视频\(videoIndex).mp4" : "\(safe).mp4",
                    url: url, text: nil, altUrls: candidates.filter { $0 != first }
                ))
            } else {
                let candidates = imageCandidates(part)
                guard let first = candidates.first, let url = URL(string: first) else { continue }
                imageIndex += 1
                items.append(MediaItem(
                    id: "\(code)_img\(imageIndex)", kind: .image,
                    label: "原图 \(imageIndex)", fileName: "\(safe)_\(imageIndex).jpg",
                    url: url, text: nil, altUrls: Array(candidates.dropFirst())
                ))
            }
        }

        if items.isEmpty && caption.isEmpty {
            throw ParseError("这个帖子读不到内容，请确认链接是否有效")
        }

        items.append(MediaItem(
            id: "\(code)_cap", kind: .caption, label: "原文案",
            fileName: "\(safe)_文案.txt", url: nil, text: caption
        ))
        return ParseResult(platform: .instagram, title: title,
                           author: author.isEmpty ? nil : author,
                           caption: caption, items: items)
    }

    /// 视频候选取分辨率最高的 mp4
    private func videoCandidates(_ part: [String: Any]) -> [String] {
        var out: [String] = []
        if let versions = arr(part, "video_versions") {
            var scored: [(Int, String)] = []
            for raw in versions {
                guard let v = raw as? [String: Any] else { continue }
                let url = str(v, "url")
                if url.isEmpty { continue }
                scored.append((int(v, "width") * int(v, "height"), url))
            }
            for pair in scored.sorted(by: { $0.0 > $1.0 }) where !out.contains(pair.1) {
                out.append(pair.1)
            }
        }
        let direct = str(part, "video_url")
        if !direct.isEmpty && !out.contains(direct) { out.append(direct) }
        return out
    }

    /// 图片候选取分辨率最高的
    private func imageCandidates(_ part: [String: Any]) -> [String] {
        var out: [String] = []
        let candidates = arr(obj(part, "image_versions2"), "candidates") ?? arr(part, "display_resources")
        if let candidates = candidates {
            var scored: [(Int, String)] = []
            for raw in candidates {
                guard let c = raw as? [String: Any] else { continue }
                let url = str(c, "url")
                if url.isEmpty { continue }
                scored.append((int(c, "width") * int(c, "height"), url))
            }
            for pair in scored.sorted(by: { $0.0 > $1.0 }) where !out.contains(pair.1) {
                out.append(pair.1)
            }
        }
        let display = str(part, "display_url")
        if !display.isEmpty && !out.contains(display) { out.append(display) }
        return out
    }
}

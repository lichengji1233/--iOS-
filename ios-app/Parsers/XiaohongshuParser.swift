import Foundation
import WebKit

struct XiaohongshuParser {

    private struct PageInfo {
        let url: String
        let noteId: String
    }

    private let headers = [
        "Referer": "https://www.xiaohongshu.com/",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Cache-Control": "no-cache",
        "Upgrade-Insecure-Requests": "1",
    ]

    func parse(_ url: String) async throws -> ParseResult {
        let page = try await resolveNoteUrl(url)
        var note = try? await fetchNoteFromHttp(page.url, noteId: page.noteId)
        if note == nil {
            // WKWebView 兜底：真实执行页面反爬 JS 后直接读取 JS 状态
            note = await fetchNoteViaWebView(url: page.url, noteId: page.noteId)
        }
        guard let note = note else {
            throw ParseError(
                "无法读取小红书笔记。可能原因：链接已过期（请在App内重新复制最新分享链接）、" +
                    "笔记需要登录查看、或触发了平台风控验证。请稍后重试。"
            )
        }
        return buildResult(note, noteId: page.noteId)
    }

    // MARK: - 页面直取

    private func resolveNoteUrl(_ url: String) async throws -> PageInfo {
        let finalUrl = try await UrlUtils.resolveRedirect(url)
        guard let m = finalUrl.range(
            of: #"/(?:discovery/item|explore|notes)/([0-9a-fA-F]{24})"#,
            options: .regularExpression
        ) else {
            throw ParseError("未能在链接中找到小红书笔记ID，请确认分享链接有效")
        }
        let segment = String(finalUrl[m])
        let noteId = String(segment.suffix(24))
        return PageInfo(url: finalUrl, noteId: noteId)
    }

    private func fetchNoteFromHttp(_ url: String, noteId: String) async throws -> [String: Any]? {
        let (data, _) = try await UrlUtils.httpGet(url, headers: headers)
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return extractNote(from: html, noteId: noteId)
    }

    private func extractNote(from html: String, noteId: String) -> [String: Any]? {
        guard html.contains("noteDetailMap"),
              let state = extractInitialState(html),
              let map = obj(obj(state, "note"), "noteDetailMap", "note_detail_map") else {
            return nil
        }
        if let ent = map[noteId] as? [String: Any],
           let n = (ent["note"] as? [String: Any]) ?? ent,
           looksLikeNote(n) {
            return n
        }
        for (_, v) in map {
            guard let ent = v as? [String: Any] else { continue }
            let n = (ent["note"] as? [String: Any]) ?? ent
            if looksLikeNote(n) { return n }
        }
        return nil
    }

    private func looksLikeNote(_ n: [String: Any]) -> Bool {
        n["imageList"] != nil || n["image_list"] != nil ||
            n["video"] != nil || n["title"] != nil || n["desc"] != nil
    }

    private func extractInitialState(_ html: String) -> [String: Any]? {
        guard let idx = html.range(of: "window.__INITIAL_STATE__") else { return nil }
        guard let eq = html[idx.upperBound...].firstIndex(of: "=") else { return nil }
        var i = html.index(after: eq)
        while i < html.endIndex, html[i].isWhitespace { i = html.index(after: i) }
        guard i < html.endIndex, html[i] == "{" else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        var j = i
        while j < html.endIndex {
            let c = html[j]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = j; break }
                }
            }
            j = html.index(after: j)
        }
        guard let end = end else { return nil }
        let raw = String(html[i...end])
            .replacingOccurrences(of: ":undefined", with: ":null")
            .replacingOccurrences(of: ",undefined", with: ",null")
        return jsonObject(raw)
    }

    // MARK: - WKWebView 兜底

    @MainActor
    private func fetchNoteViaWebView(url: String, noteId: String) async -> [String: Any]? {
        let wv = HiddenWebView.shared.webView
        guard let u = URL(string: url) else { return nil }
        wv.stopLoading()
        wv.load(URLRequest(url: u))
        // 先给页面加载与反爬 JS 留出时间，再轮询读取 noteDetailMap
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for _ in 0..<35 {
            if let note = await evaluateNote(noteId: noteId) {
                wv.stopLoading()
                wv.load(URLRequest(url: URL(string: "about:blank")!))
                return note
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        wv.stopLoading()
        wv.load(URLRequest(url: URL(string: "about:blank")!))
        return nil
    }

    @MainActor
    private func evaluateNote(noteId: String) async -> [String: Any]? {
        let js = """
        (function(){
          try {
            var s = window.__INITIAL_STATE__;
            if (!s || !s.note || !s.note.noteDetailMap) return JSON.stringify({ok:false});
            var map = s.note.noteDetailMap;
            var key = "\(noteId)";
            if (!map[key]) {
              var keys = Object.keys(map);
              if (!keys.length) return JSON.stringify({ok:false});
              key = keys[0];
            }
            var ent = map[key];
            var note = ent && ent.note ? ent.note : ent;
            if (!note) return JSON.stringify({ok:false});
            return JSON.stringify({ok:true, note: note});
          } catch(e) { return JSON.stringify({ok:false}); }
        })()
        """
        let value = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            wvEvaluate(js) { cont.resume(with: .success($0)) }
        }
        guard let v = value,
              let data = v.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let note = obj["note"] as? [String: Any],
              looksLikeNote(note) else {
            return nil
        }
        return note
    }

    private func wvEvaluate(_ js: String, completion: @escaping (String?) -> Void) {
        HiddenWebView.shared.webView.evaluateJavaScript(js) { value, _ in
            if let s = value as? String {
                completion(s)
            } else {
                completion(nil)
            }
        }
    }

    // MARK: - 结果组装

    private func buildResult(_ note: [String: Any], noteId: String) -> ParseResult {
        let title = str(note, "title").isEmpty
            ? (str(note, "desc").isEmpty ? "小红书笔记" : str(note, "desc"))
            : str(note, "title")
        let desc = str(note, "desc").isEmpty ? title : str(note, "desc")
        let author = str(obj(note, "user"), "nickname")
        var media: [MediaItem] = []

        if let images = arr(note, "imageList", "image_list") {
            for (i, img) in images.enumerated() {
                guard let im = img as? [String: Any] else { continue }
                let raw = str(im, "urlDefault", "url_default", "url")
                let u = fixUrl(raw)
                guard !u.isEmpty else { continue }
                media.append(MediaItem(
                    id: "\(noteId)_img\(i)", kind: .image,
                    label: "原图 \(i + 1)", fileName: safeName(title, fallback: "xiaohongshu") + "_\(i + 1).jpg",
                    url: URL(string: u), text: nil
                ))
            }
        }

        if let video = obj(note, "video") {
            var candidates: [String] = []
            let direct = str(video, "url")
            if !direct.isEmpty { candidates.append(fixUrl(direct)) }
            let originKey = str(obj(video, "consumer"), "originVideoKey")
            if !originKey.isEmpty {
                for host in ["sns-video-bd.xhscdn.com", "sns-video-al.xhscdn.com",
                             "sns-video-hw.xhscdn.com", "sns-video-qc.xhscdn.com"] {
                    candidates.append("https://\(host)/\(originKey.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
                }
            }
            if let stream = obj(obj(video, "media"), "stream"),
               let h264 = arr(stream, "h264"),
               let first = h264.first as? [String: Any] {
                let master = str(first, "masterUrl", "master_url")
                if !master.isEmpty { candidates.append(fixUrl(master)) }
            }
            if let chosen = candidates.first(where: { !$0.isEmpty }),
               let url = URL(string: chosen) {
                media.append(MediaItem(
                    id: "\(noteId)_video", kind: .video,
                    label: url.absoluteString.lowercased().contains(".m3u8")
                        ? "原视频（无水印，HLS）" : "原视频（无水印）",
                    fileName: safeName(title, fallback: "xiaohongshu") + ".mp4",
                    url: url, text: nil
                ))
            }
        }

        guard !media.isEmpty else {
            throw ParseError("未找到图片或视频，可能该笔记仅文字或需要登录")
        }

        var caption = desc
        if let tags = arr(note, "tagList") {
            var tagText = ""
            for t in tags {
                if let name = str((t as? [String: Any]), "name"), !name.isEmpty {
                    tagText += "#\(name) "
                }
            }
            if !tagText.isEmpty { caption += "\n\n\(tagText)" }
        }

        media.append(MediaItem(
            id: "\(noteId)_cap", kind: .caption,
            label: "原文案", fileName: safeName(title, fallback: "xiaohongshu") + "_文案.txt",
            url: nil, text: caption
        ))
        return ParseResult(platform: .xiaohongshu, title: title, author: author, caption: caption, items: media)
    }
}

import Foundation

/// 页面取数用的小工具：括号配对、内联 JSON、正则抓取
enum WebPage {

    // MARK: - 括号配对

    /// 从 idx（必须指向 '{'）开始做括号配对，返回配对的 '}' 下标
    static func matchBrace(_ text: String, from idx: String.Index) -> String.Index? {
        guard idx < text.endIndex, text[idx] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = idx
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: - 内联 JSON

    /// 取出 `marker = {...}` 里那整段 JSON 对象（如 window.__SETUP_SERVER_STATE__）
    static func assignedJson(_ html: String, marker: String) -> [String: Any]? {
        var searchStart = html.startIndex
        while let r = html.range(of: marker, range: searchStart..<html.endIndex) {
            searchStart = r.upperBound
            guard let eq = html.range(of: "=", range: r.upperBound..<html.endIndex) else { return nil }
            if html.distance(from: r.upperBound, to: eq.lowerBound) > 3 { continue }
            var p = eq.upperBound
            while p < html.endIndex, html[p].isWhitespace { p = html.index(after: p) }
            guard p < html.endIndex, html[p] == "{" else { continue }
            guard let end = matchBrace(html, from: p) else { continue }
            let raw = String(html[p...end])
                .replacingOccurrences(of: ":undefined", with: ":null")
                .replacingOccurrences(of: ",undefined", with: ",null")
            if let obj = jsonObject(raw) { return obj }
        }
        return nil
    }

    /// 在大 JSON 里递归找当前笔记（兼容结构变动）
    static func findNote(_ node: Any, noteId: String, depth: Int = 0) -> [String: Any]? {
        if depth > 20 { return nil }
        if let dict = node as? [String: Any] {
            if looksLikeNote(dict), hasSubstance(dict),
               dict["noteId"] != nil || dict["desc"] != nil {
                let id = (dict["noteId"] as? String) ?? noteId
                if id == noteId { return dict }
            }
            for (_, value) in dict {
                if let hit = findNote(value, noteId: noteId, depth: depth + 1) { return hit }
            }
        } else if let list = node as? [Any] {
            for value in list {
                if let hit = findNote(value, noteId: noteId, depth: depth + 1) { return hit }
            }
        }
        return nil
    }

    static func looksLikeNote(_ n: [String: Any]) -> Bool {
        n["imageList"] != nil || n["image_list"] != nil ||
            n["video"] != nil || n["title"] != nil || n["desc"] != nil
    }

    /// 真正有内容的笔记对象（防止匹到 errorNoteData 之类的空壳）
    static func hasSubstance(_ n: [String: Any]) -> Bool {
        if let images = n["imageList"] as? [Any], !images.isEmpty { return true }
        if let images = n["image_list"] as? [Any], !images.isEmpty { return true }
        if let video = n["video"] as? [String: Any], !video.isEmpty { return true }
        if let desc = n["desc"] as? String, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let title = n["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    // MARK: - 正则

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              group < m.numberOfRanges else { return nil }
        let range = m.range(at: group)
        if range.location == NSNotFound { return nil }
        return ns.substring(with: range)
    }

    static func allMatches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = text as NSString
        var out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard group < m.numberOfRanges else { continue }
            let range = m.range(at: group)
            if range.location == NSNotFound { continue }
            out.append(ns.substring(with: range))
        }
        return out
    }

    /// 把页面里的 JSON 转义写法还原成正常网址
    static func normalizeEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
    }

    static func unescapeHtml(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func stripHtml(_ html: String) -> String {
        var s = html
        for pattern in [#"<br\s*/?>"#, #"</p>"#] {
            s = s.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return unescapeHtml(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 逐个探测候选地址，返回第一个能下动的
    static func pickReachable(_ candidates: [String], headers: [String: String] = [:]) async -> String? {
        for url in candidates where !url.isEmpty {
            guard let target = URL(string: url) else { continue }
            var request = URLRequest(url: target)
            request.timeoutInterval = 12
            request.setValue(UAForProbe, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=0-1024", forHTTPHeaderField: "Range")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let (_, resp) = try? await UrlUtils.session.data(for: request),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                return url
            }
        }
        return nil
    }

    private static let UAForProbe = UrlUtils.UA.desktop
}

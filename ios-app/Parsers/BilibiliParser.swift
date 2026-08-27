import Foundation

struct BilibiliParser {

    private let headers = [
        "Referer": "https://www.bilibili.com/",
        "Origin": "https://www.bilibili.com",
    ]

    func parse(_ url: String) async throws -> ParseResult {
        let finalUrl = try await UrlUtils.resolveRedirect(url)
        guard let bv = finalUrl.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression) else {
            throw ParseError("未能在链接中找到B站BV号")
        }
        let bvid = String(finalUrl[bv])
        guard let view = obj(try await getJson("https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)"), "data") else {
            throw ParseError("获取视频信息失败，可能是番剧/版权受限视频或链接无效")
        }
        let title = str(view, "title").isEmpty ? "B站视频" : str(view, "title")
        let desc = str(view, "desc")
        let owner = str(obj(view, "owner"), "name")
        let pic = str(view, "pic")
        var media: [MediaItem] = []

        let pages = arr(view, "pages") ?? []
        if pages.count > 1 {
            for (i, p) in pages.enumerated() {
                guard let page = p as? [String: Any] else { continue }
                let cid = int(page, "cid")
                let part = str(page, "part").isEmpty ? "P\(i + 1)" : str(page, "part")
                if let v = try? await findPlayUrl(bvid: bvid, cid: cid, title: title) {
                    media.append(MediaItem(
                        id: "\(bvid)_p\(i)", kind: .video,
                        label: "\(v.label) · \(part)", fileName: safeName(title, fallback: "bilibili") + ".mp4",
                        url: v.url, text: nil
                    ))
                }
            }
            if media.isEmpty { throw ParseError("无法获取分P视频地址，可能因版权或登录限制") }
        } else {
            let cid = int(view, "cid")
            guard let v = try? await findPlayUrl(bvid: bvid, cid: cid, title: title) else {
                throw ParseError("无法获取视频地址，可能因版权或登录限制")
            }
            media.append(v)
        }

        if !pic.isEmpty {
            media.append(MediaItem(
                id: "\(bvid)_cover", kind: .image,
                label: "封面图", fileName: safeName(title, fallback: "bilibili") + "_封面.jpg",
                url: URL(string: pic), text: nil
            ))
        }
        let caption = desc.isEmpty ? title : "\(title)\n\n\(desc)"
        media.append(MediaItem(
            id: "\(bvid)_cap", kind: .caption,
            label: "原文案", fileName: safeName(title, fallback: "bilibili") + "_文案.txt",
            url: nil, text: caption
        ))
        return ParseResult(platform: .bilibili, title: title, author: owner.isEmpty ? nil : owner,
                           caption: caption, items: media)
    }

    private func findPlayUrl(bvid: String, cid: Int, title: String) async throws -> MediaItem? {
        for qn in [80, 64, 32, 16] {
            guard let data = obj(try await getJson(
                "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&cid=\(cid)&qn=\(qn)&fnval=1&fourk=1"
            ), "data") else { continue }
            if let durl = arr(data, "durl"),
               let first = durl.first as? [String: Any] {
                let u = str(first, "url")
                guard !u.isEmpty else { continue }
                return MediaItem(
                    id: "\(bvid)_\(cid)", kind: .video,
                    label: qualityLabel(data, qn: qn), fileName: safeName(title, fallback: "bilibili") + ".mp4",
                    url: URL(string: u), text: nil
                )
            }
        }
        return nil
    }

    private func qualityLabel(_ data: [String: Any], qn: Int) -> String {
        guard let descs = arr(data, "accept_description"),
              let qs = arr(data, "accept_quality") else { return "视频" }
        for (i, q) in qs.enumerated() {
            if (q as? Int) == qn, i < descs.count {
                return (descs[i] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "视频"
            }
        }
        return "视频"
    }

    private func getJson(_ url: String) async throws -> [String: Any]? {
        let (data, resp) = try await UrlUtils.httpGet(url, headers: headers)
        guard resp.statusCode == 200 else { return nil }
        return try? jsonObject(data)
    }
}

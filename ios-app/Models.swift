import Foundation

enum Platform: String {
    case douyin = "抖音"
    case xiaohongshu = "小红书"
    case bilibili = "B站"
    case weibo = "微博"
    case x = "X（推特）"
    case instagram = "Instagram"
    case unknown = "未知平台"
}

enum MediaKind: String {
    case video = "视频"
    case image = "图片"
    case caption = "文案"
}

struct MediaItem: Identifiable {
    let id: String
    let kind: MediaKind
    let label: String
    let fileName: String
    let url: URL?
    let text: String?
    /// 备用地址：第一个下不动时依次重试
    var altUrls: [String] = []

    var isHls: Bool {
        guard let url = url else { return false }
        return url.pathExtension.lowercased() == "m3u8" ||
            url.lastPathComponent.lowercased().contains("m3u8") ||
            url.absoluteString.lowercased().contains(".m3u8")
    }

    /// 所有可尝试的下载地址（主地址 + 备用地址）
    var candidateURLs: [URL] {
        var out: [URL] = []
        if let url = url { out.append(url) }
        for s in altUrls {
            if let u = URL(string: s), !out.contains(u) { out.append(u) }
        }
        return out
    }
}

struct ParseResult {
    let platform: Platform
    let title: String
    let author: String?
    let caption: String
    let items: [MediaItem]
}

struct ParseError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }
    var errorDescription: String? { message }
}

enum Platforms {
    static let supported: [Platform] = [
        .douyin, .xiaohongshu, .bilibili, .weibo, .x, .instagram,
    ]

    static let supportedText = supported.map { $0.rawValue }.joined(separator: " / ")
}

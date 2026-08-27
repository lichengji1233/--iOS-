import Foundation

enum Platform: String {
    case douyin = "抖音"
    case xiaohongshu = "小红书"
    case bilibili = "B站"
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

    var isHls: Bool {
        guard let url = url else { return false }
        return url.pathExtension.lowercased() == "m3u8" ||
            url.lastPathComponent.lowercased().contains("m3u8") ||
            url.absoluteString.lowercased().contains(".m3u8")
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

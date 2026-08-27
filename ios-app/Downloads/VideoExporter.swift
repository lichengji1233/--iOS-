import AVFoundation
import Foundation

enum VideoExporter {
    /// 将 HLS（m3u8）流导出为本地 mp4（无 DRM 的流可用）
    static func exportHls(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ParseError("无法创建视频导出任务")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    cont.resume()
                case .failed:
                    cont.resume(throwing: export.error ?? ParseError("视频导出失败"))
                case .cancelled:
                    cont.resume(throwing: ParseError("视频导出已取消"))
                default:
                    cont.resume(throwing: ParseError("视频导出失败"))
                }
            }
        }
        return out
    }
}

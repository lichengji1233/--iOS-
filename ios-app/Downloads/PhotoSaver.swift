import Foundation
import Photos
import UIKit

enum PhotoSaver {

    static func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
                cont.resume(returning: s)
            }
        }
        return status == .authorized || status == .limited
    }

    static func saveImage(_ data: Data) async throws {
        guard let image = UIImage(data: data) else {
            throw ParseError("图片数据无法解析")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func saveVideo(from url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}

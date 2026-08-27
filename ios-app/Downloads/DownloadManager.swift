import Combine
import Foundation

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var progress: [String: Double] = [:]

    private var session: URLSession!
    private var handlers: [String: (Double) -> Void] = [:]
    private var continuations: [String: CheckedContinuation<URL, Error>] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 下载到临时文件，返回本地 URL
    func download(item: MediaItem, headers: [String: String] = [:]) async throws -> URL {
        guard let url = item.url else { throw ParseError("没有可下载的地址") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(UrlUtils.UA.desktop, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let key = url.absoluteString
        let task = session.downloadTask(with: request)
        lock.lock()
        handlers[key] = { [weak self] p in
            DispatchQueue.main.async { self?.progress[item.id] = p }
        }
        lock.unlock()

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuations[key] = cont
            lock.unlock()
            task.resume()
        }
    }

    private func takeContinuation(for key: String) -> CheckedContinuation<URL, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = continuations.removeValue(forKey: key)
        handlers.removeValue(forKey: key)
        return c
    }
}

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let url = downloadTask.originalRequest?.url else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock()
        let handler = handlers[url.absoluteString]
        lock.unlock()
        handler?(p)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let url = task.originalRequest?.url,
              let cont = takeContinuation(for: url.absoluteString) else { return }
        if let error = error {
            cont.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url,
              let cont = takeContinuation(for: url.absoluteString) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent))
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
        } catch {
            try? FileManager.default.copyItem(at: location, to: tmp)
        }
        cont.resume(returning: tmp)
    }
}

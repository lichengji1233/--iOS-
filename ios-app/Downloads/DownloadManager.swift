import Combine
import Foundation

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var progress: [String: Double] = [:]

    private var session: URLSession!
    private var keyByTask: [Int: String] = [:]
    private var continuations: [String: CheckedContinuation<URL, Error>] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 下载到临时文件：主地址失败时自动换备用地址重试
    func download(item: MediaItem, headers: [String: String] = [:]) async throws -> URL {
        let candidates = item.candidateURLs
        guard !candidates.isEmpty else { throw ParseError("没有可下载的地址") }
        var lastError: Error = ParseError("下载失败")
        for url in candidates {
            do {
                return try await download(url: url, itemId: item.id, headers: headers)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func download(url: URL, itemId: String, headers: [String: String] = [:]) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(UrlUtils.UA.desktop, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let task = session.downloadTask(with: request)
        let key = "\(itemId)#\(task.taskIdentifier)"
        lock.lock()
        keyByTask[task.taskIdentifier] = key
        lock.unlock()

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuations[key] = cont
            lock.unlock()
            task.resume()
        }
    }

    /// 直接把数据读到内存（图片用），同样支持备用地址
    func data(from item: MediaItem, headers: [String: String] = [:]) async throws -> Data {
        let candidates = item.candidateURLs
        guard !candidates.isEmpty else { throw ParseError("没有可下载的地址") }
        for url in candidates {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(UrlUtils.UA.desktop, forHTTPHeaderField: "User-Agent")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let (data, resp) = try? await UrlUtils.session.data(for: request),
               let http = resp as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               !data.isEmpty {
                return data
            }
        }
        throw ParseError("图片下载失败，可能是链接已过期")
    }

    private func takeContinuation(_ task: URLSessionTask) -> (String, CheckedContinuation<URL, Error>)? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = keyByTask.removeValue(forKey: task.taskIdentifier),
              let cont = continuations.removeValue(forKey: key) else { return nil }
        return (key, cont)
    }

    private func itemId(for task: URLSessionTask) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = keyByTask[task.taskIdentifier] else { return nil }
        return key.components(separatedBy: "#").first
    }
}

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let id = itemId(for: downloadTask) else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress[id] = value }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let (_, cont) = takeContinuation(task) else { return }
        cont.resume(throwing: error)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let (_, cont) = takeContinuation(downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            cont.resume(throwing: ParseError("下载失败 HTTP \(http.statusCode)"))
            return
        }
        let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "download"
        let safeName = name.isEmpty ? "download" : name
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + safeName)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
        } catch {
            try? FileManager.default.copyItem(at: location, to: tmp)
        }
        cont.resume(returning: tmp)
    }
}

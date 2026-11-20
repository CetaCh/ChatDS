//
//  DownloadManager.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  对应安卓 FileDown.java + MainActivity 里的 readRange / downloadCacheSize / clearDownloadCache。
//  网页导入历史时：downloadToFile 把文件下载到沙盒 Caches/imports，再用 fileSize + readRange
//  按分片读回字节（每次最多 48KB，与安卓 MAX_RANGE 一致），随后自己解析。
//

import Foundation

final class DownloadManager: NSObject, URLSessionDownloadDelegate {

    static let maxRange = 48 * 1024             // 与安卓 MainActivity.MAX_RANGE 一致

    weak var api: JSAPI?

    private var session: URLSession!
    private let lock = NSLock()
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private let queue = DispatchQueue(label: "dsfc.readRange", qos: .userInitiated, attributes: .concurrent)

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func shutdown() {
        lock.lock()
        let running = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        running.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }

    // MARK: - 下载

    func download(id: String, url: String, fileName: String) {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            reportFail(id: id, message: "下载地址无效")
            return
        }
        let dir = FileCompat.importDirectory()
        let name = sanitize(name: fileName)
        var request = URLRequest(url: target)
        // 与安卓 FileDown 的 User-Agent 保持一致
        request.setValue("ChatDS/iOS", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request) { [weak self] location, _, error in
            guard let self = self else { return }
            self.forget(id: id)
            if let error = error as NSError? {
                if error.code != NSURLErrorCancelled {
                    self.reportFail(id: id, message: error.localizedDescription)
                }
                return
            }
            guard let location = location else {
                self.reportFail(id: id, message: "下载失败")
                return
            }
            let dest = self.uniqueURL(in: dir, preferred: name)
            do {
                try FileManager.default.moveItem(at: location, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: location)
                self.reportFail(id: id, message: error.localizedDescription)
                return
            }
            DispatchQueue.main.async {
                self.api?.callDownloadDone(id: id, path: dest.path)
            }
        }
        lock.lock()
        tasks[id] = task
        lock.unlock()
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let id = tasks.first { $0.value === downloadTask }?.key
        lock.unlock()
        guard let currentId = id else { return }
        let total = max(0, totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.api?.callDownloadProgress(id: currentId, loaded: totalBytesWritten, total: total)
        }
    }

    // MARK: - 区间读取（对应安卓 readRange，返回 base64）

    func readRange(callbackId: String, path: String, start: Int64, end: Int64) {
        guard let resolved = FileCompat.resolve(path), FileManager.default.fileExists(atPath: resolved) else {
            // 安卓在文件不存在时回空串，网页据此判断结束
            DispatchQueue.main.async { [weak self] in
                self?.api?.callRange(callbackId: callbackId, base64: "")
            }
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            var base64 = ""
            if let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolved)) {
                defer { try? file.close() }
                let fileLength = (try? file.seekToEnd()) ?? 0
                let from = max(0, start)
                let to = min(max(end, from), fileLength)
                let want = min(to - from, Int64(DownloadManager.maxRange))
                if want > 0 {
                    try? file.seek(toOffset: UInt64(from))
                    let chunk = (try? file.read(upToCount: Int(want))) ?? Data()
                    base64 = chunk.base64EncodedString()
                }
            }
            DispatchQueue.main.async {
                self.api?.callRange(callbackId: callbackId, base64: base64)
            }
        }
    }

    // MARK: - 缓存统计（对应安卓 downloadCacheSize / clearDownloadCache）

    func cacheSize() -> Int64 {
        let dir = FileCompat.importDirectory()
        guard let enumerator = FileManager.default.enumerator(at: dir,
                                                             includingPropertiesForKeys: [.fileSizeKey],
                                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    func clearCache() -> Int64 {
        lock.lock()
        let running = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        running.forEach { $0.cancel() }

        let freed = cacheSize()
        let dir = FileCompat.importDirectory()
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items {
                try? FileManager.default.removeItem(at: item)
            }
        }
        return freed
    }

    // MARK: - 工具

    private func forget(id: String) {
        lock.lock()
        tasks.removeValue(forKey: id)
        lock.unlock()
    }

    private func sanitize(name: String) -> String {
        var out = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { out = "import.zip" }
        out = out.replacingOccurrences(of: "/", with: "_")
        out = out.replacingOccurrences(of: "\\", with: "_")
        out = out.replacingOccurrences(of: ":", with: "_")
        return out
    }

    private func uniqueURL(in dir: URL, preferred: String) -> URL {
        let base = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        var candidate = dir.appendingPathComponent(preferred)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = dir.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private func reportFail(id: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.api?.callDownloadFail(id: id, message: message)
        }
    }
}

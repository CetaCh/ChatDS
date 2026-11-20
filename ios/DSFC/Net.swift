//
//  Net.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  对应安卓 Net.java：把网页 fetch 的请求交给原生发出，绕开 file:// 页面访问第三方 API 的 CORS 限制。
//  所有请求都走 URLSession DataDelegate，边收边按节奏推送：
//    流式（"stream":true 或 text/event-stream）：先推 head，再按 4KB / 24ms 推 chunk（与安卓节奏一致）
//    非流式（TTS、/models、余额等）            ：读完汇聚成整段，在 __dsfcBridgeDone 里一次性交还
//  android-bridge.js 的 wantsLive 判断依据是 *请求体文本*，所以像语音识别这类
//  multipart 上传（没有 "stream":true）也必须走 chunk 路径，否则页面拿不到音频结果。
//

import Foundation

final class Net: NSObject, URLSessionDataDelegate {

    static let connectTimeout: TimeInterval = 20
    static let readTimeout: TimeInterval = 300
    static let chunkSize = 4096               // 每块推送的字节数（安卓 Net.java 同为 4096）
    static let flushInterval: TimeInterval = 0.024
    static let maxBuffered = 150 * 1024 * 1024

    weak var api: JSAPI?

    private var session: URLSession!
    private let lock = NSLock()
    private var tasks: [String: Job] = [:]

    final class Job {
        let id: String
        let scope: String
        let streaming: Bool
        var urlTask: URLSessionDataTask?
        var headSent = false
        var status = 0
        var headers: [String: String] = [:]
        var buffer = Data()
        var collected = Data()
        var overflow = false
        var cancelled = false
        var finished = false
        let started = Date()
        var lastFlush = Date()

        init(id: String, scope: String, streaming: Bool) {
            self.id = id
            self.scope = scope
            self.streaming = streaming
        }
    }

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Net.readTimeout
        config.timeoutIntervalForResource = Net.readTimeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 退出 / 重建 Shell 时整体收尾，避免连接泄漏
    func shutdown() {
        session.invalidateAndCancel()
        lock.lock()
        tasks.removeAll()
        lock.unlock()
    }

    // MARK: - 发起请求

    func start(id: String, method: String, url: String, headersJson: String, body: String, scope: String) {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fail(id: id, message: "NETERR|请求地址无效")
            return
        }
        var request = URLRequest(url: target)
        request.httpMethod = method.isEmpty ? "GET" : method.uppercased()
        request.timeoutInterval = Net.readTimeout

        let headers = parseHeaders(headersJson)
        let skipped: Set<String> = ["accept-encoding", "content-length", "host", "connection", "transfer-encoding"]
        for (name, value) in headers {
            let lower = name.lowercased()
            if skipped.contains(lower) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        // 与安卓一致：固定 identity，服务端按原样返回，避免 gzip 解压差异
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        let methodUpper = request.httpMethod ?? "GET"

        // 网页 ios-bridge.js 把 FormData 编码成 JSON 信封交过来：
        //   {"__dsfcForm":1,"contentType":"multipart/form-data; boundary=...","body":"<base64 原始 multipart>"}
        // 这里还原成真正的 multipart 正文（boundary 必须与头里一致，否则服务端解析失败）
        var payload: Data?
        if !body.isEmpty && methodUpper != "GET" && methodUpper != "HEAD" {
            if let envelope = Self.decodeFormEnvelope(body) {
                payload = envelope.body
                request.setValue(envelope.contentType, forHTTPHeaderField: "Content-Type")
            } else if let raw = Self.decodeBinaryEnvelope(body, headers: headers) {
                payload = raw.body
                if let type = raw.contentType {
                    request.setValue(type, forHTTPHeaderField: "Content-Type")
                } else if !contentType.isEmpty {
                    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                }
            } else {
                payload = Data(body.utf8)
            }
        }
        if let payload = payload {
            request.httpBody = payload
            request.setValue("\(payload.count)", forHTTPHeaderField: "Content-Length")
        }

        let wantsLive = body.range(of: "\"stream\"\\s*:\\s*true", options: .regularExpression) != nil
        let job = Job(id: id, scope: scope.isEmpty ? "main" : scope,
                      streaming: wantsLive || contentType.contains("text/event-stream"))

        lock.lock()
        tasks[id] = job
        lock.unlock()

        let urlTask = session.dataTask(with: request)
        job.urlTask = urlTask
        urlTask.resume()
    }

    /// 网页 abort 时调用：只中断当前页面的请求（与安卓 cancelAll 的作用域一致）
    func cancelAll(scope: String) {
        lock.lock()
        let victims = tasks.values.filter { $0.scope == scope || scope.isEmpty }
        for victim in victims { tasks.removeValue(forKey: victim.id) }
        lock.unlock()
        for victim in victims {
            victim.cancelled = true
            victim.buffer.removeAll()
            victim.collected.removeAll()
            victim.urlTask?.cancel()
        }
    }

    /// 余额查询（对应安卓 Net.balance：GET endpoint + /user/balance）
    func balance(id: String, endpoint: String, apiKey: String) {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        start(id: id, method: "GET", url: base + "/user/balance",
              headersJson: "{\"Authorization\":\"Bearer \(apiKey)\"}", body: "", scope: "main")
    }

    // MARK: - 请求体解码

    private struct FormEnvelope {
        let contentType: String
        let body: Data
    }

    private struct BinaryEnvelope {
        let contentType: String?
        let body: Data
    }

    /// multipart/FormData 信封
    private static func decodeFormEnvelope(_ text: String) -> FormEnvelope? {
        guard text.hasPrefix("{"),
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let flag = object["__dsfcForm"] as? Int, flag == 1,
              let body64 = object["body"] as? String,
              let body = Data(base64Encoded: body64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        let contentType = (object["contentType"] as? String) ?? ""
        guard !contentType.isEmpty else { return nil }
        return FormEnvelope(contentType: contentType, body: body)
    }

    /// 纯二进制请求体（ios-bridge.js 以 base64 直接交给原生，binary=true）
    private static func decodeBinaryEnvelope(_ text: String, headers: [(key: String, value: String)]) -> BinaryEnvelope? {
        guard !text.isEmpty, text.range(of: "\"__dsfcForm\"") == nil else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\r\n")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let compact = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        guard compact.count % 4 == 0, compact.count >= 4,
              let body = Data(base64Encoded: compact) else { return nil }
        let declared = headers.first { $0.key.lowercased() == "content-type" }?.value
        return BinaryEnvelope(contentType: declared, body: body)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = job(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        job.status = (response as? HTTPURLResponse)?.statusCode ?? 200
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (key, value) in http.allHeaderFields {
                headers["\(key)"] = "\(value)"
            }
        }
        job.headers = headers
        if job.streaming && !job.headSent {
            job.headSent = true
            let id = job.id
            let json = Self.jsonString(headers)
            let status = job.status
            DispatchQueue.main.async { [weak self] in
                self?.api?.callBridgeHead(id: id, status: status, headersJson: json)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = job(for: dataTask), !job.cancelled else { return }
        if job.streaming {
            job.buffer.append(data)
            flushIfNeeded(job, force: false)
        } else if job.collected.count + data.count > Net.maxBuffered {
            job.overflow = true
        } else {
            job.collected.append(data)
        }
    }

    func urlSession(_ session: URLSession, task urlTask: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = job(for: urlTask), !job.finished else { return }
        job.finished = true
        if job.streaming { flushIfNeeded(job, force: true) }

        lock.lock()
        tasks.removeValue(forKey: job.id)
        lock.unlock()

        if job.cancelled { return }

        let id = job.id
        let status = job.status
        let headersJson = Self.jsonString(job.headers)

        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            let message = Self.friendly(ns)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if job.streaming && job.headSent {
                    self.api?.callBridgeDone(id: id, status: -1, headersJson: headersJson,
                                             bodyBase64: "", binary: false)
                } else {
                    let errB64 = Data("NETERR|\(message)".utf8).base64EncodedString()
                    self.api?.callBridgeDone(id: id, status: -1, headersJson: "{}",
                                             bodyBase64: errB64, binary: false)
                }
            }
            return
        }

        if job.streaming {
            DispatchQueue.main.async { [weak self] in
                self?.api?.callBridgeDone(id: id, status: status, headersJson: headersJson,
                                          bodyBase64: "", binary: false)
            }
            return
        }

        if job.overflow {
            let errB64 = Data("NETERR|响应超过 150MB".utf8).base64EncodedString()
            DispatchQueue.main.async { [weak self] in
                self?.api?.callBridgeDone(id: id, status: -1, headersJson: "{}",
                                          bodyBase64: errB64, binary: false)
            }
            return
        }

        let base64 = job.collected.base64EncodedString()
        let binary = !Self.isTextual(job.headers)
        DispatchQueue.main.async { [weak self] in
            self?.api?.callBridgeDone(id: id, status: status, headersJson: headersJson,
                                      bodyBase64: base64, binary: binary)
        }
    }

    // MARK: - 分块推送

    private func flushIfNeeded(_ job: Job, force: Bool) {
        guard !job.buffer.isEmpty, !job.cancelled else { return }
        let elapsed = Date().timeIntervalSince(job.lastFlush)
        guard force || job.buffer.count >= Net.chunkSize || elapsed >= Net.flushInterval else { return }

        // 末尾可能截断多字节字符：把不完整的字节留给下一块
        let data = force ? job.buffer : Self.trimToUTF8Boundary(job.buffer)
        guard !data.isEmpty else { return }
        job.buffer.removeFirst(data.count)
        job.lastFlush = Date()
        // 同时留一份完整副本，页面的 text()/json() 回退路径也能用
        if job.collected.count + data.count <= Net.maxBuffered {
            job.collected.append(data)
        } else {
            job.overflow = true
        }
        let base64 = data.base64EncodedString()
        let id = job.id
        DispatchQueue.main.async { [weak self] in
            self?.api?.callBridgeChunk(id: id, base64: base64)
        }
    }

    private static func trimToUTF8Boundary(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        let bytes = [UInt8](data)
        var index = bytes.count - 1
        var back = 0
        while index >= 0 && back < 4 {
            let byte = bytes[index]
            if byte & 0x80 == 0 { return data }                  // ASCII：边界完整
            if byte & 0xC0 == 0xC0 {                              // 多字节首字节
                var need = 2
                if byte & 0xF0 == 0xE0 { need = 3 }
                else if byte & 0xF8 == 0xF0 { need = 4 }
                let available = bytes.count - index
                return available < need ? data.prefix(index) : data
            }
            index -= 1
            back += 1
        }
        return data
    }

    // MARK: - 工具

    private func job(for task: URLSessionTask) -> Job? {
        lock.lock()
        defer { lock.unlock() }
        return tasks.values.first { $0.urlTask === task }
    }

    private func parseHeaders(_ json: String) -> [(key: String, value: String)] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return object.map { (key: $0.key, value: "\($0.value)") }
    }

    static func jsonString(_ object: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func isTextual(_ headers: [String: String]) -> Bool {
        guard let type = headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased() else {
            return true
        }
        return type.hasPrefix("text/") || type.contains("json") || type.contains("javascript")
            || type.contains("xml") || type.contains("event-stream")
    }

    /// iOS 的网络错误是英文的，这里换成页面里能看懂的说法
    private static func friendly(_ error: NSError) -> String {
        switch error.code where error.domain == NSURLErrorDomain {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "网络连接已断开，请检查 Wi-Fi 或移动数据"
        case NSURLErrorTimedOut:
            return "请求超时，请稍后重试"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "无法解析服务器地址"
        case NSURLErrorCannotConnectToHost:
            return "无法连接服务器，请检查接口地址"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
            return "HTTPS 证书校验失败"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "系统要求使用 HTTPS（明文 HTTP 已在 Info.plist 中放开，请重新构建）"
        case NSURLErrorCancelled:
            return "请求已取消"
        default:
            return error.localizedDescription
        }
    }

    private func fail(id: String, message: String) {
        let b64 = Data(message.utf8).base64EncodedString()
        DispatchQueue.main.async { [weak self] in
            self?.api?.callBridgeDone(id: id, status: -1, headersJson: "{}", bodyBase64: b64, binary: false)
        }
    }
}

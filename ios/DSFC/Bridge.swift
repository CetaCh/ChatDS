//
//  Bridge.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  桥接层用到的公共小工具：JS 字符串转义、文件目录约定、二进制/文本判断。
//

import Foundation

/// JS 字符串字面量转义（单双引号都安全）
func jsString(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "'": out += "'"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{2028}": out += "\\u2028"
        case "\u{2029}": out += "\\u2029"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else if (32..<127).contains(scalar.value), let ascii = Unicode.Scalar(scalar.value) {
                out.unicodeScalars.append(ascii)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// 目录约定（对应安卓 getCacheDir()/imports）
enum FileCompat {
    static func importDirectory() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = root.appendingPathComponent("imports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 把网页传回的路径解析成可读写的绝对路径：
    /// iOS 的容器目录每次安装/启动都可能变化，旧路径按 “Caches/” 后缀重新定位。
    static func resolve(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if FileManager.default.fileExists(atPath: trimmed) { return trimmed }
        if let range = trimmed.range(of: "/Caches/", options: .backwards) {
            let tail = String(trimmed[range.upperBound...])
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            if let candidate = root?.appendingPathComponent(tail).path,
               FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            return root?.appendingPathComponent(tail).path
        }
        return trimmed
    }
}

/// 根据响应头判断正文是不是文本（与安卓 bridge 的 binary 判断一致）
enum BodyKind {
    static func isTextual(_ headers: [String: String]) -> Bool {
        guard let type = headers.first(where: { $0.key.lowercased() == "content-type" })?.value.lowercased() else {
            return true
        }
        return type.hasPrefix("text/") || type.contains("json") || type.contains("javascript")
            || type.contains("xml") || type.contains("event-stream") || type.contains("x-www-form-urlencoded")
    }

    /// iOS 网络错误 → 页面里能看懂的中文提示
    static func friendly(_ error: NSError) -> String {
        if error.domain == "NSURLErrorDomain" {
            switch error.code {
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
                break
            }
        }
        return error.localizedDescription
    }
}

//
//  JSAPI.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  DSFC_NATIVE 的原生实现（对应安卓 MainActivity 里的 @JavascriptInterface 方法）。
//  方法名、参数顺序与安卓保持一字不差，网页（android-bridge.js / main.de040f79.js）无需改动。
//
//  WKScriptMessageHandler 只能异步，而安卓桥是同步的，所以：
//    1. DocumentStart 注入的引导脚本给每个同步方法生成“同步代理”：
//       调用 → postMessage → 主线程临时跑 RunLoop 等原生回调 → 拿到结果同步返回
//    2. 原生处理完用 __dsfcResolve(cid, value) 把结果交还给页面
//    3. “哪个请求属于哪个页面”由 JS 记录来源页面，cancelAll 只中断该页面的请求
//

import UIKit
import WebKit
import UserNotifications

final class JSAPI {

    private weak var webView: WKWebView?
    private weak var router: RouterViewController?

    let net = Net()
    let downloads = DownloadManager()

    /// DocumentStart 注入：生成 window.DSFC_NATIVE（早于 index.html 里的 android-bridge.js）
    static let bootstrapScript = """
    (function () {
      // file:// 页面在 WKWebView 里不算“安全上下文”，网页会据此禁用语音输入等能力。
      // 这里把安全上下文标记强行打开（Wi-Fi / 局域网 http 接口同样可用）。
      try {
        Object.defineProperty(window, 'isSecureContext', { value: true, configurable: true });
        Object.defineProperty(window, 'isSecureContextWarned', { value: true, configurable: true });
      } catch (e) {
        try { window.isSecureContext = true; } catch (e2) {}
      }
      if (window.DSFC_NATIVE) return;
      var send = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dsfc;
      if (!send) return;
      var POLL_MS = 15, POLL_MAX_MS = 8000;
      function sync(call, args) {
        if (!window.__dsfcSync) window.__dsfcSync = {};
        var cid = 's' + Date.now().toString(36) + Math.random().toString(36).slice(2);
        var box = { value: null, pending: true };
        window.__dsfcSync[cid] = box;
        try { send.postMessage({ call: call, args: args, cid: cid }); }
        catch (e) { delete window.__dsfcSync[cid]; return null; }
        // 原生回调总在 JS 代码块返回后执行；这里必须一直阻塞等待，直到 __dsfcResolve 置位
        var waited = 0;
        while (box.pending && waited < POLL_MAX_MS) {
          busy(POLL_MS);
          waited += POLL_MS;
        }
        var out = box.value;
        delete window.__dsfcSync[cid];
        return out === undefined ? null : out;
      }
      function busy(ms) {
        var end = Date.now() + ms;
        while (Date.now() < end) { /* 等原生回调 */ }
      }
      function fire(call, args) {
        try { send.postMessage({ call: call, args: args }); } catch (e) { /* ignore */ }
      }
      window.__dsfcResolve = function (cid, value) {
        var box = window.__dsfcSync && window.__dsfcSync[cid];
        if (box) { box.value = value; box.pending = false; }
      };
      window.__dsfcSetScope = function (name) { window.__dsfcScope = String(name || 'main'); return true; };
      // 网页里的“上传 → 失败 → 改走原生 HTTP”分支：给主窗口发 request
      var api = {
        info: function () { return sync('info', []); },
        http: function (id, method, url, headersJson, body, binary) {
          fire('http', [id, method, url, headersJson, body, binary ? '1' : '0', window.__dsfcScope || 'main']);
        },
        cancelAll: function () { fire('cancelAll', [window.__dsfcScope || 'main']); },
        downloadToFile: function (id, url, fileName) { fire('downloadToFile', [id, url, fileName]); },
        fileSize: function (path) {
          var v = sync('fileSize', [path]);
          return (typeof v === 'number') ? v : (parseInt(v, 10) || 0);
        },
        readRange: function (cbId, path, start, end) { fire('readRange', [cbId, path, start, end]); },
        clearDownloadCache: function () { return parseInt(sync('clearDownloadCache', []), 10) || 0; },
        downloadCacheSize: function () { return parseInt(sync('downloadCacheSize', []), 10) || 0; },
        setSystemBars: function (dark) { fire('setSystemBars', [!!dark]); },
        notify: function (title, text, ongoing) { fire('notify', [title || '', text || '', !!ongoing]); },
        balance: function (id, endpoint, apiKey) { fire('balance', [id, endpoint, apiKey]); },
        route: function (home) { fire('route', [!!home]); },
        requestNotify: function () { fire('requestNotify', []); },
        openSetting: function (which) { fire('openSetting', [which || '']); },
        saveFile: function (fileName, dataUrl) { fire('saveFile', [fileName || '', dataUrl || '']); },
        shareFile: function (path) { fire('shareFile', [path || '']); },
        previewFile: function (path) { fire('previewFile', [path || '']); },
        debugTopbar: function () {},
        debugGeom: function () {},
        statusBarInfo: function () { return sync('statusBarInfo', []); }
      };
      try { Object.defineProperty(window, 'DSFC_NATIVE', { value: api, configurable: true }); }
      catch (e) { window.DSFC_NATIVE = api; }
    })();
    """

    /// 页面初始化时执行一次：同步系统深浅色到 <html data-theme> 与 meta[name=theme-color>
    /// （对应安卓 onPageFinished 里的处理）；并确保页面没有多余的键盘留白
    static let pageInitScript = """
    (function () {
      function paint(dark) {
        try {
          document.documentElement.setAttribute('data-theme', dark ? 'dark' : 'light');
          var meta = document.querySelector('meta[name="theme-color"]');
          if (meta) meta.setAttribute('content', dark ? '#151517' : '#ffffff');
        } catch (e) {}
      }
      try {
        var mq = window.matchMedia('(prefers-color-scheme: dark)');
        paint(mq.matches);
        var onChange = function (e) { paint(e.matches); };
        if (mq.addEventListener) mq.addEventListener('change', onChange);
        else if (mq.addListener) mq.addListener(onChange);
      } catch (e) {}
    })();
    """

    init(webView: WKWebView, router: RouterViewController) {
        self.webView = webView
        self.router = router
        net.api = self
        downloads.api = self
    }

    // MARK: - 分发

    /// - Parameters:
    ///   - cid: 同步调用带的回调编号；异步调用为 nil
    func handle(call: String, args: [Any], cid: String?) {
        switch call {
        case "info":
            finish(cid, appInfo())
        case "statusBarInfo":
            finish(cid, statusBarInfo())
        case "fileSize":
            finish(cid, NSNumber(value: fileSize(string(args, 0))))
        case "downloadCacheSize":
            finish(cid, NSNumber(value: downloads.cacheSize()))
        case "clearDownloadCache":
            finish(cid, NSNumber(value: downloads.clearCache()))
        case "readRange":
            downloads.readRange(callbackId: string(args, 0), path: string(args, 1),
                                start: int64(args, 2), end: int64(args, 3))
        case "http":
            net.start(id: string(args, 0), method: string(args, 1), url: string(args, 2),
                      headersJson: string(args, 3), body: string(args, 4),
                      scope: string(args, 6))
        case "cancelAll":
            net.cancelAll(scope: string(args, 0))
        case "downloadToFile":
            downloads.download(id: string(args, 0), url: string(args, 1), fileName: string(args, 2))
        case "setSystemBars":
            setSystemBars(dark: bool(args, 0))
        case "notify":
            notify(title: string(args, 0), text: string(args, 1))
        case "requestNotify":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        case "openSetting":
            openSettings(string(args, 0))
        case "balance":
            net.balance(id: string(args, 0), endpoint: string(args, 1), apiKey: string(args, 2))
        case "saveFile":
            saveFile(name: string(args, 0), dataUrl: string(args, 1))
        case "shareFile":
            if let url = URL(string: string(args, 0)) { router?.exportFiles([url]) }
        case "previewFile":
            if let url = URL(string: string(args, 0)) { router?.previewFile(url) }
        default:
            break
        }
    }

    // MARK: - 回传

    func finish(_ cid: String?, _ value: Any?) {
        guard let webView = webView, let cid = cid else { return }
        let literal: String
        if let string = value as? String {
            literal = jsString(string)
        } else if let number = value as? NSNumber {
            literal = number.stringValue
        } else {
            literal = "null"
        }
        webView.evaluateJavaScript("window.__dsfcResolve(\(jsString(cid)), \(literal))")
    }

    /// 异步回调：直接执行 JS（对应安卓 evaluateJavascript）
    func evaluate(_ js: String) {
        webView?.evaluateJavaScript(js)
    }

    /// 调用网页的某个全局回调。规则与安卓 bridge 一致：
    ///   安卓：web.evaluateJavascript("window.__dsfcBridgeDone&&window.__dsfcBridgeDone(a,b,c)")
    func callGlobal(_ name: String, _ args: [String]) {
        let list = args.map { jsString($0) }.joined(separator: ",")
        evaluate("window.\(name)&&window.\(name)(\(list))")
    }

    /// 流式分块 / 头部：空串表示“无数据”
    func callBridgeHead(id: String, status: Int, headersJson: String) {
        callGlobal("__dsfcBridgeHead", [id, "\(status)", headersJson])
    }

    func callBridgeChunk(id: String, base64: String) {
        guard !base64.isEmpty else { return }
        callGlobal("__dsfcBridgeChunk", [id, base64])
    }

    func callBridgeDone(id: String, status: Int, headersJson: String, bodyBase64: String, binary: Bool) {
        callGlobal("__dsfcBridgeDone", [id, "\(status)", headersJson, bodyBase64, binary ? "true" : "false"])
    }

    func callDownloadProgress(id: String, loaded: Int64, total: Int64) {
        callGlobal("__dsfcDownloadProgress", [id, "\(loaded)", "\(total)"])
    }

    func callDownloadDone(id: String, path: String) {
        callGlobal("__dsfcDownloadDone", [id, path])
    }

    func callDownloadFail(id: String, message: String) {
        callGlobal("__dsfcDownloadFail", [id, message])
    }

    func callRange(callbackId: String, base64: String) {
        callGlobal("__dsfcRange", [callbackId, base64])
    }

    // MARK: - 同步接口的实现

    func appInfo() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let code = info["CFBundleVersion"] as? String ?? "1"
        return "{\"version\":\"\(version)\",\"versionCode\":\"\(code)\",\"platform\":\"ios\",\"sdk\":\(UIDevice.current.systemVersion)}"
    }

    func statusBarInfo() -> String {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let safe = keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        return "{\"top\":\(safe.top),\"bottom\":\(safe.bottom),\"dark\":\(dark)}"
    }

    func fileSize(_ path: String) -> Int64 {
        guard let path = FileCompat.resolve(path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    func setSystemBars(dark: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let router = self?.router else { return }
            router.updateTheme(dark: dark)
        }
    }

    func notify(title: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "dsfc-status",
                                                                     content: content,
                                                                     trigger: nil))
    }

    func openSettings(_ which: String) {
        DispatchQueue.main.async {
            // iOS 不允许直接跳到具体的通知/电池设置，只能落到本应用的设置页
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
    }

    /// 网页把文件以 dataURL 交上来：写入导入目录，再弹系统分享存到「文件」
    func saveFile(name: String, dataUrl: String) {
        var fileName = name.isEmpty ? "attachment" : name
        if let slash = fileName.lastIndex(of: "/") {
            fileName = String(fileName[fileName.index(after: slash)...])
        }
        var payload = dataUrl
        if payload.hasPrefix("data:"), let comma = payload.firstIndex(of: ",") {
            payload = String(payload[payload.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return }
        let target = FileCompat.importDirectory().appendingPathComponent(fileName)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.router?.exportFiles([target])
        }
    }

    // MARK: - 参数取值

    private func string(_ args: [Any], _ index: Int) -> String {
        guard index < args.count else { return "" }
        if let value = args[index] as? String { return value }
        if let value = args[index] as? NSNumber { return value.stringValue }
        if args[index] is NSNull { return "" }
        return "\(args[index])"
    }

    private func int64(_ args: [Any], _ index: Int) -> Int64 {
        guard index < args.count else { return 0 }
        if let value = args[index] as? NSNumber { return value.int64Value }
        if let value = args[index] as? String { return Int64(Double(value) ?? 0) }
        return 0
    }

    private func bool(_ args: [Any], _ index: Int) -> Bool {
        guard index < args.count else { return false }
        if let value = args[index] as? Bool { return value }
        if let value = args[index] as? NSNumber { return value.boolValue }
        if let value = args[index] as? String { return value == "true" || value == "1" }
        return false
    }
}

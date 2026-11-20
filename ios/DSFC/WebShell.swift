//
//  WebShell.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  WKWebView 容器：配置与安卓 MainActivity 对齐
//    - 加载 bundle 内的 www/index.html（离线，file:// 源）
//    - 注入 DSFC_NATIVE：用 WKScriptMessageHandler 把网页的调用桥到原生
//      （安卓是 addJavascriptInterface 同步调用，iOS 用 postMessage + 回调还原同步语义）
//    - UA 追加 " DSFCApp/1.0"（与安卓一致，服务端可据此识别 App）
//
//  键盘：页面顶部就是输入区，iOS 的 WKWebView 不会像安卓 adjustResize 那样自动缩小页面，
//  这里监听键盘通知，把键盘高度转成 --dsfc-keyboard CSS 变量交给页面做避让。
//

import UIKit
import WebKit

final class WebShell: UIView {

    private(set) var webView: WKWebView!
    private(set) var bridge: JSAPI!
    private weak var router: RouterViewController?

    init(frame: CGRect, router: RouterViewController) {
        self.router = router
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: 1)

        let controller = DSFCScriptHandler()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // 手机上按手机版式排版
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let userController = WKUserContentController()
        // 注意顺序：同步桥必须第一个注入，早于 index.html 里的 android-bridge.js
        userController.addUserScript(WKUserScript(source: JSAPI.bootstrapScript,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true))
        // 页面初始化：同步系统深浅色到 <html data-theme>（对应安卓 onPageFinished 的处理）
        userController.addUserScript(WKUserScript(source: JSAPI.pageInitScript,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        userController.add(controller, name: DSFCScriptHandler.messageName)
        config.userContentController = userController

        let web = WKWebView(frame: .zero, configuration: config)
        web.backgroundColor = UIColor(white: 1, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.keyboardDismissMode = .none
        web.scrollView.bounces = false
        web.scrollView.alwaysBounceVertical = false
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = router.appDelegate
        web.uiDelegate = router.appDelegate
        if #available(iOS 16.4, *) {
            web.isInspectable = false
        }

        // 安卓 UA 追加 " DSFCApp/1.0"；iOS 默认 UA 已经是 iPhone 版 Safari
        if let userAgent = web.value(forKey: "userAgent") as? String, !userAgent.contains("DSFCApp") {
            web.customUserAgent = userAgent + " DSFCApp/1.0"
        }

        addSubview(web)
        WebShell.pin(web, to: self)
        webView = web

        bridge = JSAPI(webView: web, router: router)
        controller.callback = { [weak self] call, args, cid in
            self?.bridge.handle(call: call, args: args, cid: cid)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 布局

    static func pin(_ child: UIView, to parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    // MARK: - 加载

    func loadLocalPage() {
        let bundle = Bundle.main
        guard let index = bundle.url(forResource: "index", withExtension: "html", subdirectory: "www") else {
            router?.shellFailed("找不到网页资源 www/index.html")
            return
        }
        let root = index.deletingLastPathComponent()
        webView.loadFileURL(index, allowingReadAccessTo: root)
    }
}

/// 接收网页发来的桥调用：postMessage({call:'http', args:[...], cid:'s1'})
final class DSFCScriptHandler: NSObject, WKScriptMessageHandler {
    static let messageName = "dsfc"
    var callback: ((String, [Any], String?) -> Void)?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == DSFCScriptHandler.messageName else { return }
        guard let body = message.body as? [String: Any],
              let call = body["call"] as? String else { return }
        let args = body["args"] as? [Any] ?? []
        let cid = body["cid"] as? String
        callback?(call, args, cid)
    }
}

/// evaluateJavaScript 的同步封装：只用于 __dsfcBack 这类毫秒级的同步 DOM 操作
extension WKWebView {

    @discardableResult
    func syncEvalString(_ javaScript: String) -> String? {
        var finished = false
        var out: Any?
        var iterations = 0
        evaluateJavaScript(javaScript) { value, _ in
            out = value
            finished = true
        }
        while !finished && iterations < 400 {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            iterations += 1
        }
        if let string = out as? String { return string }
        if let number = out as? NSNumber { return number.stringValue }
        return nil
    }
}

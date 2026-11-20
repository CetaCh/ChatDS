//
//  AppDelegate.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  这是 Android 版 com.cetach.dsfc（DS-FC）的 iOS 对应实现。
//  网页部分（www 目录）与安卓版完全一致，原生层只负责：
//    1. 用 WKWebView 加载 bundle 里的离线网页
//    2. 提供 JS 桥 DSFC_NATIVE（HTTP 转发 / 文件下载 / 文件选择 / 状态栏 / 通知）
//    3. 处理 iPhone 特有的交互：侧滑返回、键盘避让、安全区、分享导出
//

import UIKit
import WebKit
import AVFoundation
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, WKNavigationDelegate, WKUIDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        if #available(iOS 13.0, *) {
            // 有 SceneDelegate 时窗口由 scene(_:willConnectTo:) 创建并挂到场景上，
            // 这里不能再自建窗口，否则会出现「窗口没有 windowScene」导致的空白页。
        } else {
            let root = RouterViewController()
            let win = UIWindow(frame: UIScreen.main.bounds)
            win.rootViewController = root
            window = win
            win.makeKeyAndVisible()
            DispatchQueue.main.async {
                root.installShell()
            }
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 语音输入需要麦克风：配置成允许录音并走扬声器播放
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: - WKNavigationDelegate

    private var router: RouterViewController? { window?.rootViewController as? RouterViewController }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        router?.shellLoaded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        router?.shellFailed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        router?.shellFailed(error.localizedDescription)
    }

    /// 网页里的外链（http/https）留在 App 内打开，保持登录态；其他 scheme 交给系统
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if scheme == "file" || scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        if scheme == "http" || scheme == "https" {
            // 顶栏主页等外链用 App 内 Safari 打开（保持登录态，也能随时关掉回聊天）
            if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true {
                router?.openInBrowser(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        decisionHandler(.cancel)
    }

    // MARK: - WKUIDelegate

    /// 网页里的 <input type="file">（上传附件）走这里弹系统文件选择器
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        router?.presentPicker(parameters: parameters, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        topMost()?.present(alert, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        topMost()?.present(alert, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        topMost()?.present(alert, animated: true, completion: nil)
    }

    // MARK: - 通知

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    private func topMost() -> UIViewController? {
        var vc = window?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

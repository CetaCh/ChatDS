//
//  RouterViewController.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  根控制器：装壳、侧滑/返回键的路由、文件选择、导出分享、附件预览。
//

import UIKit
import WebKit
import QuickLook
import SafariServices
import UniformTypeIdentifiers

final class RouterViewController: UIViewController, QLPreviewControllerDataSource {

    enum Stage {
        case boot
        case web
        case failed
    }

    private(set) var stage: Stage = .boot
    private(set) var shell: WebShell?
    private var bootOverlay: UIView?
    private var errorView: UIView?
    private var spinner: UIActivityIndicatorView?
    private var isDarkBars = false
    private var observerTokens: [NSObjectProtocol] = []

    var bridge: JSAPI? { shell?.bridge }

    var appDelegate: AppDelegate? { UIApplication.shared.delegate as? AppDelegate }

    // 文件选择与采集（网页点击 <input type="file"> 时由 WKUIDelegate 调用）
    private var pendingPanel: (([URL]?) -> Void)?
    private var pendingPreview: URL?

    // MARK: - 生命周期

    override var preferredStatusBarStyle: UIStatusBarStyle { isDarkBars ? .lightContent : .darkContent }
    override var childForStatusBarStyle: UIViewController? { nil }
    // iPhone 锁竖屏（与安卓版一致）；iPad 支持任意方向，方便横屏或分屏使用
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }
    // iPad 分屏 / 台前调度时窗口可缩放：网页靠 window.innerWidth 自动重排，
    // 这里只需保证每次尺寸变化都重新推送安全区（见 viewDidLayoutSubviews）
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 1, alpha: 1)

        // 键盘避让：安卓用的是 adjustResize（窗口缩小），iOS 这里把键盘高度交给页面
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            self?.applyKeyboard(note: note, visible: true)
        })
        observerTokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            self?.applyKeyboard(note: note, visible: false)
        })
        observerTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            self?.applyKeyboard(note: nil, visible: false)
        })
    }

    deinit {
        observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 让网页知道刘海 / 底部条的尺寸，页面据此做安全区留白
        let safe = view.safeAreaInsets
        let js = "window.__dsfcSafeArea={top:\(safe.top),right:\(safe.right),bottom:\(safe.bottom),left:\(safe.left)};"
            + "document.documentElement.style.setProperty('--dsfc-safe-top','\(safe.top)px');"
            + "document.documentElement.style.setProperty('--dsfc-safe-bottom','\(safe.bottom)px');"
            + "if(window.dispatchEvent){window.dispatchEvent(new Event('dsfc-safe-area'))}"
        shell?.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        shell?.webView.evaluateJavaScript("window.dispatchEvent(new Event('dsfc-memory-warning'))", completionHandler: nil)
    }

    /// 网页请求系统栏配色（对应安卓 setSystemBars / applySystemBarTheme）
    func updateTheme(dark: Bool) {
        guard isDarkBars != dark else { return }
        isDarkBars = dark
        setNeedsStatusBarAppearanceUpdate()
        UIView.animate(withDuration: 0.2) {
            self.view.backgroundColor = dark ? UIColor(red: 0.082, green: 0.082, blue: 0.090, alpha: 1) : .white
            self.bootOverlay?.backgroundColor = dark ? UIColor(red: 0.082, green: 0.082, blue: 0.090, alpha: 1) : .white
            self.errorView?.backgroundColor = dark ? UIColor(red: 0.082, green: 0.082, blue: 0.090, alpha: 1) : .white
        }
        if let spinner = spinner, #available(iOS 13.0, *) {
            spinner.color = dark ? UIColor(white: 0.62, alpha: 1) : UIColor(white: 0.45, alpha: 1)
        }
    }

    /// 键盘事件 → CSS 变量，页面底部的输入区随之抬升
    private func applyKeyboard(note: Notification?, visible: Bool) {
        var height: CGFloat = 0
        if visible, let note = note,
           let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let overlap = view.bounds.maxY - view.convert(frame, from: nil).minY
            height = max(0, overlap)
        }
        let js = "document.documentElement.style.setProperty('--dsfc-keyboard','\(Int(height))px');"
            + "window.dispatchEvent(new Event('dsfc-keyboard'))"
        shell?.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - 装壳

    /// AppDelegate 在窗口上屏后调用（此时引擎已经初始化完毕，可以安全创建 WKWebView）
    func installShell() {
        guard shell == nil else { return }
        errorView?.removeFromSuperview()
        errorView = nil
        stage = .web

        let web = WebShell(frame: view.bounds, router: self)
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        WebShell.pin(web, to: view)
        shell = web
        installEdgePan()

        showBootOverlay()
        web.loadLocalPage()
    }

    func shellLoaded() {
        stage = .web
        hideBootOverlay()
    }

    func shellFailed(_ message: String) {
        hideBootOverlay()
        showError(with: message)
    }

    // MARK: - 启动画面（白色底 + 图标，避免黑屏）

    private func showBootOverlay() {
        guard bootOverlay == nil else { return }
        let overlay = UIView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let isDark = traitCollection.userInterfaceStyle == .dark
        overlay.backgroundColor = isDark ? UIColor(red: 0.082, green: 0.082, blue: 0.090, alpha: 1)
                                         : UIColor.white

        let image = UIImage(named: "SplashLogo")
        let icon = UIImageView(image: image)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 22
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -20),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96)
        ])

        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        if #available(iOS 13.0, *) {
            indicator.color = isDark ? UIColor(white: 0.6, alpha: 1) : UIColor(white: 0.5, alpha: 1)
        }
        indicator.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 28),
            indicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor)
        ])
        spinner = indicator

        view.addSubview(overlay)
        bootOverlay = overlay
        overlay.alpha = 1
    }

    private func hideBootOverlay() {
        guard let overlay = bootOverlay else { return }
        bootOverlay = nil
        UIView.animate(withDuration: 0.22, animations: { overlay.alpha = 0 }, completion: { _ in
            overlay.removeFromSuperview()
        })
    }

    private func showError(with message: String) {
        if errorView == nil {
            let container = UIView(frame: view.bounds)
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.backgroundColor = .white

            let title = UILabel()
            title.text = "页面加载失败"
            title.font = UIFont.systemFont(ofSize: 19, weight: .semibold)
            title.textColor = UIColor(white: 0.1, alpha: 1)
            title.textAlignment = .center

            let detail = UILabel()
            detail.numberOfLines = 0
            detail.font = UIFont.systemFont(ofSize: 13)
            detail.textColor = UIColor(white: 0.45, alpha: 1)
            detail.textAlignment = .center

            let retry = UIButton(type: .system)
            retry.setTitle("重新加载", for: .normal)
            retry.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            retry.setTitleColor(.white, for: .normal)
            retry.backgroundColor = UIColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1)
            retry.layer.cornerRadius = 18
            retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
            retry.heightAnchor.constraint(equalToConstant: 44).isActive = true
            retry.widthAnchor.constraint(equalToConstant: 160).isActive = true

            let stack = UIStackView(arrangedSubviews: [title, detail, retry])
            stack.axis = .vertical
            stack.spacing = 16
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
            ])
            detail.text = message
            view.addSubview(container)
            errorView = container
        }
        stage = .failed
    }

    @objc private func retryTapped() {
        installShell()
        shell?.loadLocalPage()
    }

    // MARK: - 返回（侧滑 / 导航栏返回）

    /// 返回 true 表示网页接管了这次返回（关弹窗 / 关侧栏）；false 表示已到首页
    func dispatchBack() -> Bool {
        guard let web = shell?.webView else { return false }
        let result = web.syncEvalString("(function(){try{return String(window.__dsfcBack?window.__dsfcBack():'')}catch(e){return ''}})()")
        return result == "overlay" || result == "sidebar"
    }

    /// 异步执行网页的返回逻辑（对应安卓 dispatchBack → __dsfcBack）
    func runBack(_ web: WKWebView) {
        web.evaluateJavaScript("(function(){try{return String(window.__dsfcBack?window.__dsfcBack():'')}catch(e){return ''}})()") { [weak self] result, _ in
            let value = (result as? String) ?? ""
            // 到首页：给一次明确提示（iPhone 由用户自己上滑退出，不主动杀进程）
            if value == "exit" {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.flashHomeHint()
            }
        }
    }

    private func flashHomeHint() {
        guard errorView == nil else { return }
        let label = UILabel()
        label.text = "已在首页"
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.72)
        label.textAlignment = .center
        label.layer.cornerRadius = 14
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            label.widthAnchor.constraint(equalToConstant: 96),
            label.heightAnchor.constraint(equalToConstant: 28)
        ])
        UIView.animate(withDuration: 0.18, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0.9, animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    // MARK: - 返回手势（iPhone 没有返回键，用左边缘右滑代替）

    private func installEdgePan() {
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edge.edges = .left
        edge.delegate = self
        view.addGestureRecognizer(edge)
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        if gesture.state == .ended, let web = shell?.webView {
            runBack(web)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: - 文件选择

    func presentPicker(parameters: WKOpenPanelParameters, completion: @escaping ([URL]?) -> Void) {
        // 上一次的选择回调如果没走完（比如连续点两次），先给它一个空结果，避免网页一直等待
        if let previous = pendingPanel {
            previous([])
        }
        pendingPanel = completion
        presentDocumentPicker(allowMultiple: parameters.allowsMultipleSelection)
    }

    /// 从「文件 App / iCloud 云盘 / 其他 App 提供的文稿」里挑文件
    private func presentDocumentPicker(allowMultiple: Bool) {
        var types: [UTType] = [.item]
        if let images = UTType("public.image") { types.append(images) }
        if let movies = UTType("public.movie") { types.append(movies) }
        if let audio = UTType("public.audio") { types.append(audio) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowMultiple
        picker.delegate = self
        // 选完（多选时点「打开」/「完成」）由 documentPicker(_:didPickDocumentsAt:) 回到网页
        topPresented().present(picker, animated: true)
    }

    private func finishPanel(_ urls: [URL]?) {
        guard let callback = pendingPanel else { return }
        pendingPanel = nil
        callback(urls)
    }

    /// 下载完成后导出：单个文件走系统分享（可存到「文件」、发到微信等），多个走文件导出面板
    func exportFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 面板可能由桥的异步回调触发，此时路由器上已经挂了别的视图，必须从最上层弹出
        let host = topPresented()
        if urls.count == 1, let only = urls.first {
            let activity = UIActivityViewController(activityItems: [only], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            }
            host.present(activity, animated: true)
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        host.present(picker, animated: true)
    }

    /// 预览附件（PDF / 图片 / 文本）
    func previewFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        pendingPreview = url
        let preview = QLPreviewController()
        preview.dataSource = self
        topPresented().present(preview, animated: true)
    }

    /// 外链：用 App 内的 Safari 视图打开，右上角「完成」即可回到聊天
    func openInBrowser(_ url: URL) {
        guard URL(string: url.absoluteString) != nil else { return }
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .pageSheet
        topPresented().present(safari, animated: true)
    }

    private func topPresented() -> UIViewController {
        var vc: UIViewController = self
        while let presented = vc.presentedViewController, !presented.isBeingDismissed {
            vc = presented
        }
        return vc
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return pendingPreview == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return (pendingPreview ?? URL(fileURLWithPath: "")) as NSURL
    }
}

extension RouterViewController: UIGestureRecognizerDelegate {
    /// 只在页面没有横向滑动控件抢手势时响应（侧边栏抽屉在左侧，用屏幕最左 16pt 区分）
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        return touch.location(in: view).x < 18
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return false
    }
}

extension RouterViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPanel(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPanel([])
    }
}

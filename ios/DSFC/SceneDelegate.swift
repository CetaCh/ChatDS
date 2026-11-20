//
//  SceneDelegate.swift
//  DSFC — ChatDS 的 iOS 外壳
//
//  Info.plist 声明了 UIApplicationSceneManifest，所以 iOS 13 起由这里接管窗口：
//  AppDelegate 在 didFinishLaunching 里建好的 window 要在这里挂到场景上。
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        let win = appDelegate?.window ?? UIWindow(frame: windowScene.coordinateSpace.bounds)
        win.windowScene = windowScene
        if win.rootViewController == nil {
            // 窗口上屏之后再装 WKWebView，避免首帧空白
            let root = RouterViewController()
            win.rootViewController = root
            DispatchQueue.main.async {
                root.installShell()
            }
        }
        window = win
        appDelegate?.window = win
        win.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.applicationDidBecomeActive(UIApplication.shared)
    }
}

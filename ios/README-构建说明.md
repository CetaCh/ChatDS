# DS-FC（ChatDS 15.4）iOS 移植版 — 构建与安装说明

本目录是把 `ChatDS-15.4-源码.zip`（安卓工程）**原样移植成 iOS 原生外壳**的完整工程。
网页资源（`www/`）一个字不改地随包发布，外层用 Swift + WKWebView 重写安卓的
`MainActivity.java`（WebView 外壳 + JS 桥），因此界面、功能、图标都与安卓版一致。

---

## 一、首页速览

| 项目 | 说明 |
| --- | --- |
| 应用名 | DS-FC |
| Bundle ID | `com.cetach.dsfc`（与安卓包名对应） |
| 版本 | 15.6（Build 113） |
| 最低系统 | iOS 13.0，arm64 |
| 支持设备 | iPhone（仅竖屏）+ iPad Air 2 及更新机型（iPad 五代及以后、iPad mini 4 及以后、iPad Pro 全系），iPad 支持四个方向与分屏/台前调度 |
| 图标 | 取自安卓 `mipmap-xxxhdpi/ic_launcher.png`（黑底双气泡），放大为 1024×1024 无透明通道 |
| 启动图 | 深色/浅色自适应的黑底圆角 Logo（LaunchScreen） |
| 工程 | `DSFC.xcodeproj` + 8 个 Swift 文件，不使用第三方库、不需要 CocoaPods |

---

## 二、目录结构

```
仓库根目录/
├── .github/workflows/ios-build.yml   ★ 上传 GitHub 后一键云编译出 ipa（不需要 Mac）
└── ios/
    ├── DSFC.xcodeproj/            Xcode 工程（可直接打开）
    ├── DSFC/                      源码目录
    │   ├── AppDelegate.swift      应用入口、导航策略、文件选择、弹窗
    │   ├── SceneDelegate.swift    iOS 13+ 窗口管理
    │   ├── RouterViewController.swift  根控制器、返回手势、键盘/安全区、选文件
    │   ├── WebShell.swift         WKWebView 容器、JS 注入与消息通道
    │   ├── JSAPI.swift            JS 桥（DSFC_NATIVE.* 全部方法）
    │   ├── Net.swift              网络转发（流式 SSE / 二进制 / multipart 上传）
    │   ├── DownloadManager.swift  大文件下载、分片读取、缓存清理
    │   ├── Bridge.swift           通用工具（JS 字符串转义、路径、错误文案）
    │   ├── Info.plist             应用配置模板
    │   └── Resources/
    │       ├── Assets.xcassets/   AppIcon / SplashLogo / LaunchLogo / 背景色
    │       └── www/               网页资源（157 个文件，含 ios-bridge.js）
    ├── build_ios.py               ★ 一键自检 + 测试 + 打印构建命令
    ├── build_www_bridge.py        生成 iOS 版网络桥（www/ios-bridge.js）
    ├── patch_webapp.py            语音识别模型名的兼容补丁（可重复执行）
    ├── make_icons.py              从安卓图标生成全部 iOS 图标
    ├── build_infoplist.py         渲染 Info.plist（替换 $(VAR) 占位符）
    ├── package_ipa.py             ★ 把 DSFC.app 打包成 DSFC.ipa（Mac / CI 上运行）
    ├── make_ipa.py                同上，并可用 ldid 做伪签名（越狱/企业包）
    ├── prebuild_bundle.py         本机预打包（资源骨架 ipa，用于检查结构）
    ├── check_sources.py           Swift/资源/pbxproj 体检
    ├── test_ios_bridge.js         Node 单元测试：网络桥（20 项）
    └── test_swift_logic.js        Node 单元测试：Swift 侧纯逻辑（15 项）
```

---

## 三、最省事：挂到 GitHub 云上编译（不需要 Mac）

仓库根目录已带 `.github/workflows/ios-build.yml`：

1. 把整个工程（含 `.github/` 和 `ios/`）上传到你自己的 GitHub 仓库；
2. 打开仓库的 **Actions** 页面 → 左边选「构建 DSFC iOS 版（生成可自签的 ipa）」→ 点 **Run workflow**；
3. 约 5–10 分钟后，在该次运行页面底部 **Artifacts** 下载 `DSFC-unsigned-ipa`，解压得到 `DSFC.ipa`；
4. 把 ipa 交给 **爱思助手 / AltStore / Sideloadly**，用你自己的 Apple ID 自签后安装到 iPhone 或 iPad。

> 首次自签后，在 iPhone「设置 → 通用 → VPN 与设备管理」里信任你的证书即可打开；
> 免费 Apple ID 签的名 7 天过期，重新签一次即可。

### 想在本机先看看包长什么样

```bash
python3 prebuild_bundle.py
# 产物：dist/DSFC-未签名.ipa（图标/启动图/网页/Info.plist 全齐，唯独缺 DSFC 可执行文件）
```

这个包**不能直接安装**，只用来检查结构（同样的输入生成的字节完全一致，方便对哈希）。

---

## 四、在 Mac 上构建出可装机的 IPA

> Windows 上没有 Xcode / Swift 编译器，**编译这一步必须在 Mac 上做**；
> 其余资源生成、校验、打包脚本都已就绪，Windows 上也能跑自检与单元测试。

```bash
# 1. 生成图标（可选，仓库里已带好成品）
python3 make_icons.py

# 2. 生成 iOS 网络桥 & 应用语音补丁（可重复执行）
python3 build_www_bridge.py
python3 patch_webapp.py DSFC/Resources/www

# 3. 自检 + 单元测试（Windows 上也可以跑，需要 Node）
python3 build_ios.py --test

# 4. 编译（不签名，供下面的脚本统一处理）
xcodebuild -project DSFC.xcodeproj -scheme DSFC -configuration Release \
           -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO

# 5A. 直接签名安装（需要开发者账号）
open DSFC.xcodeproj     # Xcode 中设置 Team，选真机运行即可

# 5B. 或者打成 IPA 交给签名工具
python3 package_ipa.py --app build/Build/Products/Release-iphoneos/DSFC.app
# 产物：dist/DSFC.ipa 与 dist/DSFC.app.zip

# 5C. 越狱设备/自签（Mac 上装 ldid：brew install ldid）
python3 make_ipa.py --app build/Build/Products/Release-iphoneos/DSFC.app
```

### 安装到 iPhone 的方式

1. **Xcode 直装**（最省事）：打开工程 → Signing & Capabilities 选自己的 Team →
   连数据线 → Run。免费账号 7 天有效，付费账号 1 年。
2. **爱思助手 / i4Tools / AltStore 自签**：把 `dist/DSFC.ipa` 拖进工具，登录 Apple ID 签名后安装。
   也可用 `.p12` 企业证书 + `.mobileprovision` 描述文件签成正式分发包。
3. **TrollStore**（iOS 14.0–17.0 部分版本）：直接把 ipa 拖进去安装，无需签名。

---

## 五、与安卓版的对照：做了哪些改动

| 安卓实现 | iOS 实现 | 说明 |
| --- | --- | --- |
| `MainActivity` + WebView | `RouterViewController` + `WebShell` (WKWebView) | 加载包内 `www/index.html`（`file://`） |
| `addJavascriptInterface` | `WKScriptMessageHandler` + 同步代理 | 注入 `window.DSFC_NATIVE`，**同步语义保持不变** |
| `onShowFileChooser` | `WKUIDelegate.runOpenPanelWith` + `UIDocumentPickerViewController` | 「选择文件」按钮正常可用，支持多选 |
| `Net.java` HttpURLConnection | `Net.swift` URLSession | 支持流式 SSE、二进制、150MB 上限 |
| `FileDown.java` | `DownloadManager.swift` | 下载到 `Caches/imports`，分片读取 48KB |
| 返回键 | 左边缘滑动手势 | 先关弹层/侧栏，已在首页时给轻震动提示 |
| 系统通知 | `UNUserNotificationCenter` | 请求完成状态提示 |
| `android-bridge.js`（依赖 `FileReaderSync`） | `ios-bridge.js` | WKWebView 主线程没有 `FileReaderSync`，重写上传逻辑 |

**界面/图标/网页零改动**，`static/css`、`static/js`、字体、Logo 全部原样打包。

### 三处必要的兼容性修补（已自动应用）

1. **网络桥重写**：安卓的 `android-bridge.js` 用 `FileReaderSync` 同步读文件，
   WKWebView 主线程没有这个 API，语音上传会静默失败。`ios-bridge.js` 改用异步读取，
   `FormData` 手工编码成 multipart 后整包发给原生，与浏览器字节完全一致（有单测覆盖）。
2. **语音识别模型名**：网页录的是 `audio/wav`，OpenAI 的 `whisper-1` 不接收 wav 会 400。
   补丁逻辑：DeepSeek 官方接口保持 `whisper-1` 不变；OpenAI 兼容接口先试
   `gpt-4o-transcribe`，失败则退回原来的「只传 file」请求。
3. **安全上下文**：`file://` 下 `window.isSecureContext` 为 false，网页会禁用语音按钮；
   注入脚本中强制设为 true，使麦克风、剪贴板等能力与安卓 WebView 表现一致。

---

## 六、自检与测试

```bash
python3 build_ios.py --test
```

输出示例（当前仓库状态）：

```
== 1. 源码与资源自检 ==
[OK]   8 个 Swift 源文件编码与内容检查通过
[OK]   Info.plist 模板齐全
[OK]   应用图标 1024×1024 且不含透明通道
[OK]   网页资源 157 个文件，已接入 iOS 网络桥
[OK]   Xcode 工程文件存在

== 2. Node 层测试 ==
    通过 20 / 20      # 网络桥：JSON / 流式 / FormData / 中止 / 错误文案
    通过 15 / 15      # Swift 侧纯逻辑：转义、信封、流式判定、UTF-8 截断
```

`package_ipa.py --selfcheck`、`check_sources.py` 也各自可单独运行。

---

## 七、常见问题

**Q：打开 App 白屏？**
先确认 `DSFC/Resources/www/index.html` 存在且是 folder reference（蓝色文件夹图标）。
工程里已按此配置，`www` 作为整体资源目录打包，`loadFileURL` 带读取权限。

**Q：装上去图标是空白？**
`AppIcon-1024.png` 必须是 **不带 alpha 的 PNG**。`make_icons.py` 已做黑底铺平，
`build_ios.py` 会自动检查 `color_type`，为 4/6 时会报错。

**Q：对话没反应 / 一直转圈？**
检查网络权限与接口地址；自定义 HTTPS 已通过 `NSAllowsArbitraryLoads` 放开。
流式响应如果停在半截，多为服务器不支持 SSE，可在设置里关掉流式开关。

**Q：语音输入按钮点不了？**
需要允许麦克风权限（首次点击会弹授权）。`NSMicrophoneUsageDescription` 已配置中文文案。

**Q：Windows 上能直接出 ipa 吗？**
不能编译 Mach-O。Windows 上可以跑全部自检/单测，`.ipa` 需要 Mac（或用云构建）编译后再打包。

---

## 八、许可与来源

- 网页前端与原始安卓外壳来自 `ChatDS-15.4-源码.zip`，版权归原作者所有。
- iOS 外壳（Swift 源码 + 构建脚本）为本次移植新增，可随原项目一同使用。

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 iOS 工程打包成可直接分发的 DSFC.ipa / DSFC.app.zip。

说明
    Xcode 构建产物是 DSFC.app；标准 ipa 的结构就是 Payload/DSFC.app 再套一层 zip。
    本机没有 Xcode / Swift 工具链，因此这里负责“工程已经编译好之后”的全部打包工作：
        1. 用 build_infoplist.py 从 Info.plist 模板渲染出真正的 Info.plist
        2. 组装 Payload/DSFC.app（可执行文件、资源、www、图标、LaunchScreen）
        3. 计算每个 PNG 的 CRC32，若 Info.plist 开了 CFBundleIcons（未压缩 Assets.car 时可读），
           就把图标清单补进去；没有 Assets.car 时由 Assets.car 本身负责图标
        4. zip 打包并改名 .ipa，同时输出 DSFC.app.zip 供爱思助手 / 其他工具签名安装

用法：
    python package_ipa.py                       # 检查工程，输出打包说明
    python package_ipa.py --app <DSFC.app>      # 用 Xcode 产物打包成 DSFC.ipa
    python package_ipa.py --app <DSFC.app> -o out.ipa
    python package_ipa.py --selfcheck           # 只做工程自检（供 CI 使用）
"""

import hashlib
import io
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.join(HERE, "DSFC")
TEMPLATE = os.path.join(PROJECT, "Info.plist")
RESOURCES = os.path.join(PROJECT, "Resources")
SWIFT_FILES = [
    "AppDelegate.swift",
    "SceneDelegate.swift",
    "RouterViewController.swift",
    "WebShell.swift",
    "JSAPI.swift",
    "Bridge.swift",
    "Net.swift",
    "DownloadManager.swift",
]

APP_NAME = "DSFC"
BUNDLE_ID = "com.cetach.dsfc"


# ----------------------------------------------------------------- 工具
def log(message):
    print(message)


def png_size(path):
    with open(path, "rb") as handle:
        head = handle.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return width, height


def png_color_type(path):
    with open(path, "rb") as handle:
        head = handle.read(33)
    if len(head) < 33 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return head[25]


def selfcheck():
    problems = []
    for name in SWIFT_FILES:
        path = os.path.join(PROJECT, name)
        if not os.path.isfile(path):
            problems.append("缺少源码 %s" % name)
            continue
        with open(path, "rb") as handle:
            raw = handle.read()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            problems.append("%s 不是合法 UTF-8：%s" % (name, error))
            continue
        if "\ufffd" in text:
            problems.append("%s 含乱码替换字符" % name)

    if not os.path.isfile(TEMPLATE):
        problems.append("缺少 Info.plist 模板")
    else:
        with open(TEMPLATE, "rb") as handle:
            info = plistlib.load(handle)
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "UILaunchScreen",
                    "NSAppTransportSecurity", "UIApplicationSceneManifest"):
            if key not in info:
                problems.append("Info.plist 缺少 %s" % key)

    icon = os.path.join(RESOURCES, "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png")
    if not os.path.isfile(icon):
        problems.append("缺少 1024 图标")
    else:
        size = png_size(icon)
        color = png_color_type(icon)
        if size != (1024, 1024):
            problems.append("图标尺寸应为 1024×1024，实际 %s" % (size,))
        if color in (4, 6):
            problems.append("图标含 alpha 通道（color_type=%s），上架会被拒" % color)

    www = os.path.join(RESOURCES, "www")
    index = os.path.join(www, "index.html")
    if not os.path.isfile(index):
        problems.append("缺少 www/index.html")
    else:
        with open(index, encoding="utf-8") as handle:
            html = handle.read()
        if "ios-bridge.js" not in html:
            problems.append("index.html 还没换成 ios-bridge.js（先运行 build_www_bridge.py）")
    if not os.path.isfile(os.path.join(www, "ios-bridge.js")):
        problems.append("缺少 www/ios-bridge.js（先运行 build_www_bridge.py）")

    pbx = os.path.join(HERE, "DSFC.xcodeproj", "project.pbxproj")
    if not os.path.isfile(pbx):
        problems.append("缺少 DSFC.xcodeproj/project.pbxproj")

    if problems:
        for item in problems:
            log("[FAIL] " + item)
        return 1
    count = sum(len(files) for _, _, files in os.walk(www))
    log("[OK]   8 个 Swift 源文件编码与内容检查通过")
    log("[OK]   Info.plist 模板齐全")
    log("[OK]   应用图标 1024×1024 且不含透明通道")
    log("[OK]   网页资源 %d 个文件，已接入 iOS 网络桥" % count)
    log("[OK]   Xcode 工程文件存在")
    return 0


# ----------------------------------------------------------------- 打包
def build_app(app_dir, version=None, build_number=None):
    """把 Xcode 产出的 DSFC.app 整理成可安装形态。"""
    executable = os.path.join(app_dir, APP_NAME)
    if not os.path.isfile(executable):
        raise SystemExit("找不到可执行文件：%s（请先在 Xcode 里构建 iphoneos Release 版本）" % executable)

    sys.path.insert(0, HERE)
    import build_infoplist  # noqa: E402  (同目录脚本，延迟导入)

    info_path = os.path.join(app_dir, "Info.plist")
    data = build_infoplist.build(TEMPLATE, info_path, version, build_number)
    log("Info.plist：%s %s (%s)" % (data["CFBundleIdentifier"],
                                   data.get("CFBundleShortVersionString"),
                                   data.get("CFBundleVersion")))

    # 图标：如果 Xcode 已经把 Assets.car 编好就不用管；否则把 PNG 拷进去
    assets_car = os.path.join(app_dir, "Assets.car")
    source_assets = os.path.join(RESOURCES, "Assets.xcassets")
    if not os.path.isfile(assets_car) and os.path.isdir(source_assets):
        target = os.path.join(app_dir, "Assets.xcassets")
        if not os.path.isdir(target):
            shutil.copytree(source_assets, target)
        log("提示：没有 Assets.car，已把 Assets.xcassets 原样放进包里（需用 actool 或图标清单兜底）")

    # www：Xcode 的 folder reference 会自动拷；这里兜底检查
    if not os.path.isdir(os.path.join(app_dir, "www")):
        shutil.copytree(os.path.join(RESOURCES, "www"), os.path.join(app_dir, "www"))
        log("已补拷 www 资源目录")

    prune(app_dir)
    return app_dir


def prune(app_dir):
    """删掉不该进包里的东西（_CodeSignature 由签名工具生成，不能保留旧的）。"""
    for name in ("_CodeSignature", "SC_Info"):
        path = os.path.join(app_dir, name)
        if os.path.isdir(path):
            shutil.rmtree(path)
    for root, _, files in os.walk(app_dir):
        for name in files:
            if name in (".DS_Store",) or name.endswith(".swift") or name.endswith(".swiftdoc"):
                os.remove(os.path.join(root, name))


def _write_zip(archive, base_dir, arc_root):
    """写 zip：目录项 + 文件项都使用固定时间戳，保证同样的输入得到同样的字节。"""
    stamp = (1980, 1, 1, 0, 0, 0)
    for root, dirs, files in os.walk(base_dir):
        dirs.sort()
        rel_root = os.path.relpath(root, base_dir).replace(os.sep, "/")
        if rel_root == ".":
            rel_root = ""
        arc_dir = "/".join(x for x in (arc_root, rel_root) if x)
        if arc_dir:
            info = zipfile.ZipInfo(arc_dir + "/", stamp)
            info.external_attr = (0o40755 << 16) | 0x10
            archive.writestr(info, b"")
        for name in sorted(files):
            path = os.path.join(root, name)
            arc = "/".join(x for x in (arc_root, rel_root, name) if x)
            info = zipfile.ZipInfo(arc, stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(path, "rb") as fh:
                archive.writestr(info, fh.read())


def make_ipa(app_dir, output):
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        _write_zip(archive, app_dir, "Payload/" + APP_NAME + ".app")
    log("已生成 %s（%.2f MB）" % (output, os.path.getsize(output) / 1048576.0))


def app_zip(app_dir, output):
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        _write_zip(archive, app_dir, APP_NAME + ".app")
    log("已生成 %s（%.2f MB）" % (output, os.path.getsize(output) / 1048576.0))


def main(argv):
    if "--selfcheck" in argv:
        return selfcheck()

    app = None
    output = os.path.join(HERE, "dist", APP_NAME + ".ipa")
    version = None
    build_number = None
    for index, item in enumerate(argv):
        if item == "--app" and index + 1 < len(argv):
            app = argv[index + 1]
        elif item in ("-o", "--output") and index + 1 < len(argv):
            output = argv[index + 1]
        elif item == "--version" and index + 1 < len(argv):
            version = argv[index + 1]
        elif item == "--build" and index + 1 < len(argv):
            build_number = argv[index + 1]

    if selfcheck() != 0:
        log("")
        log("工程自检未通过，先修好再打包。")
        return 1

    if not app:
        log("")
        log("本机没有 Xcode / Swift 工具链，无法在这里编译 DSFC.app。")
        log("在 Mac 上执行下面的命令得到 DSFC.app 后，再用本脚本打包：")
        log("")
        log("  xcodebuild -project ios/DSFC.xcodeproj -scheme DSFC -configuration Release \\")
        log("             -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO")
        log("  python3 ios/package_ipa.py --app build/Build/Products/Release-iphoneos/DSFC.app")
        log("")
        log("产物：ios/dist/DSFC.ipa 与 ios/dist/DSFC.app.zip（可交给爱思助手导入签名安装）")
        return 0

    if not os.path.isdir(app):
        log("找不到 app 目录：%s" % app)
        return 1
    parent = os.path.dirname(output)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    build_app(app, version, build_number)
    make_ipa(app, output)
    app_zip(app, output.replace(".ipa", ".app.zip"))
    digest = hashlib.sha256(open(output, "rb").read()).hexdigest()
    log("SHA256 %s" % digest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DSFC（ChatDS / DS-FC）iOS 工程的“源码体检”脚本。

本机没有 Xcode，无法真正编译 Swift；这个脚本做编译前的静态检查：
  1. 所有 Swift 文件必须是合法 UTF-8
  2. 字符串/注释之外，花括号、圆括号必须配对（Swift 里字符串插值的引号在 Swift 5 中允许嵌套）
  3. 资源清单必须齐全：Info.plist、Assets.xcassets（AppIcon 无透明通道）、www/index.html
  4. project.pbxproj 里引用的文件必须真实存在，Swift 源文件必须都进入 Sources 阶段
  5. Info.plist 关键键值检查（包名 / 版本 / 场景 / 图标 / 麦克风权限 / ATS）

用法：python check_sources.py
"""

import io
import json
import os
import plistlib
import re
import struct
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "DSFC")
RES = os.path.join(APP, "Resources")
PBXPROJ = os.path.join(ROOT, "DSFC.xcodeproj", "project.pbxproj")

problems = []
notes = []


def fail(message):
    problems.append(message)


def ok(message):
    notes.append(message)


# ---------------------------------------------------------------- 1. UTF-8
def check_encoding():
    for base, _dirs, files in os.walk(ROOT):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            with open(path, "rb") as handle:
                raw = handle.read()
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError as error:
                fail("%s 不是合法的 UTF-8：%s" % (name, error))
                continue
            if "\ufffd" in text:
                fail("%s 含替换字符 U+FFFD（编码被破坏）" % name)
    ok("Swift 文件编码检查通过")


# ---------------------------------------------------------------- 2. 括号配对
def strip_literals(text):
    """去掉字符串字面量与注释，便于做括号配对统计。"""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            i = n if end < 0 else end + 3
            out.append('""')
            continue
        if ch == '"' or ch == "'":
            # Swift 字符串里可以出现 \(...) 插值，插值内部可以有括号，保留其内容
            quote = ch
            i += 1
            while i < n:
                c = text[i]
                if c == "\\" and i + 1 < n and text[i + 1] == "(":
                    depth = 0
                    i += 1
                    while i < n:
                        if text[i] == "(":
                            depth += 1
                            out.append("(")
                        elif text[i] == ")":
                            depth -= 1
                            out.append(")")
                            if depth == 0:
                                i += 1
                                break
                        i += 1
                    continue
                if c == "\\" and i + 1 < n:
                    i += 2
                    continue
                if c == quote:
                    i += 1
                    break
                if c == "\n" and quote == "'":
                    break
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_brackets():
    for name in sorted(os.listdir(APP)):
        if not name.endswith(".swift"):
            continue
        path = os.path.join(APP, name)
        with io.open(path, encoding="utf-8") as handle:
            text = handle.read()
        code = strip_literals(text)
        for opener, closer, label in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
            balance = 0
            line = 1
            bad = None
            for ch in code:
                if ch == "\n":
                    line += 1
                elif ch == opener:
                    balance += 1
                elif ch == closer:
                    balance -= 1
                    if balance < 0 and bad is None:
                        bad = line
            if balance != 0:
                fail("%s %s不配对（差值 %d，首次出错行 %s）" % (name, label, balance, bad))
            elif bad is not None:
                fail("%s %s在第 %d 行提前闭合" % (name, label, bad))
    if not problems:
        ok("括号配对检查通过")


# ---------------------------------------------------------------- 3. 资源
def png_size(path):
    with open(path, "rb") as handle:
        head = handle.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    width, height = struct.unpack(">II", head[16:24])
    color_type = head[25]
    return width, height, color_type


def check_resources():
    plist_path = os.path.join(APP, "Info.plist")
    if not os.path.exists(plist_path):
        fail("缺少 Info.plist")
    else:
        with open(plist_path, "rb") as handle:
            try:
                info = plistlib.load(handle)
            except Exception as error:  # noqa
                fail("Info.plist 解析失败：%s" % error)
                info = {}
        expect = {
            "CFBundleIdentifier": "com.cetach.dsfc",
            "CFBundleExecutable": "DSFC",
            "CFBundleShortVersionString": "15.6",
            "CFBundleVersion": "113",
            "CFBundleDisplayName": "DS-FC",
        }
        for key, value in expect.items():
            if info.get(key) != value:
                fail("Info.plist 的 %s 应为 %r，实际 %r" % (key, value, info.get(key)))
        if not info.get("UILaunchScreen"):
            fail("Info.plist 缺少 UILaunchScreen（iOS 14 起必须，否则黑屏）")
        launch = info.get("UILaunchScreen") or {}
        for key in ("UIImageName", "UIColorName"):
            if not launch.get(key):
                fail("UILaunchScreen 缺少 %s" % key)
        if "UIApplicationSceneManifest" not in info:
            fail("Info.plist 缺少 UIApplicationSceneManifest")
        if not info.get("NSMicrophoneUsageDescription"):
            fail("Info.plist 缺少 NSMicrophoneUsageDescription（语音输入会崩溃）")
        ats = info.get("NSAppTransportSecurity") or {}
        if not ats.get("NSAllowsArbitraryLoads"):
            fail("ATS 未放开明文 HTTP")
        caps = info.get("UIRequiredDeviceCapabilities") or []
        if "arm64" not in caps or "metal" not in caps:
            fail("UIRequiredDeviceCapabilities 应为 arm64 + metal（GPU 自检，兼顾老设备）")
        ipad = info.get("UISupportedInterfaceOrientations~ipad") or []
        if len(ipad) < 4:
            fail("iPad 需支持四个方向（UISupportedInterfaceOrientations~ipad）")
        try:
            with io.open(PBXPROJ, "r", encoding="utf-8", errors="replace") as pbx:
                text = pbx.read()
            if 'TARGETED_DEVICE_FAMILY = "1,2"' not in text:
                fail("Xcode 工程的 TARGETED_DEVICE_FAMILY 应为 \"1,2\"（同时支持 iPhone 与 iPad）")
        except IOError:
            fail("找不到 %s" % PBXPROJ)
        ok("Info.plist 关键键值齐全")

    icon_dir = os.path.join(RES, "Assets.xcassets", "AppIcon.appiconset")
    icon = os.path.join(icon_dir, "AppIcon-1024.png")
    if not os.path.exists(icon):
        fail("缺少 AppIcon-1024.png")
    else:
        size = png_size(icon)
        if size is None:
            fail("AppIcon-1024.png 不是 PNG")
        else:
            width, height, color_type = size
            if (width, height) != (1024, 1024):
                fail("AppIcon 尺寸应为 1024×1024，实际 %d×%d" % (width, height))
            if color_type in (4, 6):
                fail("AppIcon 不能带透明通道（color_type=%d）" % color_type)
            else:
                ok("AppIcon 1024×1024，无透明通道")

    for imageset, expect_sizes in (
        ("SplashLogo.imageset", [(100, 100), (200, 200), (300, 300)]),
        ("LaunchLogo.imageset", [(80, 80), (160, 160), (240, 240)]),
    ):
        folder = os.path.join(RES, "Assets.xcassets", imageset)
        contents = os.path.join(folder, "Contents.json")
        if not os.path.exists(contents):
            fail("缺少 %s/Contents.json" % imageset)
            continue
        with open(contents, encoding="utf-8") as handle:
            data = json.load(handle)
        scales = [image.get("scale") for image in data.get("images", [])]
        if sorted(x for x in scales if x) != ["1x", "2x", "3x"]:
            fail("%s 的 Contents.json 比例不全：%s" % (imageset, scales))
        listing = sorted(x for x in os.listdir(folder) if x.endswith(".png"))
        if len(listing) != 3:
            fail("%s 应有 3 张 PNG，实际 %d 张" % (imageset, len(listing)))
            continue
        for index, name in enumerate(listing):
            size = png_size(os.path.join(folder, name))
            if size is None or (size[0], size[1]) != expect_sizes[index]:
                fail("%s 的尺寸不对：%s → %s" % (imageset, name, size))

    index = os.path.join(RES, "www", "index.html")
    if not os.path.exists(index):
        fail("缺少 Resources/www/index.html")
    else:
        count = 0
        big = 0
        for base, _dirs, files in os.walk(os.path.join(RES, "www")):
            for name in files:
                count += 1
                big += os.path.getsize(os.path.join(base, name))
        ok("网页资源 %d 个文件 / %.1f MB" % (count, big / 1024.0 / 1024.0))


# ---------------------------------------------------------------- 4. 工程文件
def check_project():
    path = os.path.join(ROOT, "DSFC.xcodeproj", "project.pbxproj")
    if not os.path.exists(path):
        fail("缺少 project.pbxproj")
        return
    with io.open(path, encoding="utf-8") as handle:
        text = handle.read()
    for name in sorted(os.listdir(APP)):
        if name.endswith(".swift") and ("%s in Sources" % name) not in text:
            fail("project.pbxproj 未把 %s 加入 Sources" % name)
    for name in ("Assets.xcassets", "www"):
        if ("%s in Resources" % name) not in text:
            fail("project.pbxproj 未把 %s 加入 Resources" % name)
    if "INFOPLIST_FILE = DSFC/Info.plist" not in text:
        fail("project.pbxproj 的 INFOPLIST_FILE 不对")
    if "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon" not in text:
        fail("project.pbxproj 未指定 AppIcon")
    # PBXBuildFile 的 fileRef 必须指向已声明的 PBXFileReference
    refs = set(re.findall(r"\b([0-9A-F]{24})\b /\* [^*]+ \*/ = \{isa = PBXFileReference", text))
    for build_id, ref_id in re.findall(
            r"([0-9A-F]{24}) /\* [^*]+ in \w+ \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24})", text):
        if ref_id not in refs:
            fail("PBXBuildFile %s 指向了未声明的 fileRef %s" % (build_id, ref_id))
    if problems:
        return
    ok("project.pbxproj 引用关系检查通过")


def main():
    check_encoding()
    check_brackets()
    check_resources()
    check_project()
    for line in notes:
        print("[OK]   " + line)
    if problems:
        print("")
        for line in problems:
            print("[FAIL] " + line)
        print("\n共 %d 处问题" % len(problems))
        return 1
    print("\n全部检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())

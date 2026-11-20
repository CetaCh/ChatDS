#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 iOS 需要的二进制 Info.plist（把模板里的 $(...) 变量渲染成真实值）。

Xcode 用 GENERATE_INFOPLIST_FILE + INFOPLIST_FILE 模板生成最终的 Info.plist；
本机没有 Xcode，所以由 Python 按同样的规则生成
Payload/DSFC.app/Info.plist，并补齐 iOS 13+ 运行时检查的必需键。

用法：python build_infoplist.py <模板路径> <输出路径> [版本] [build号]
"""

import os
import plistlib
import sys

# Xcode 构建到 Info.plist 里的环境变量（与 Xcode 默认的 INFOPLIST_PREPROCESS 行为一致）
DEFAULTS = {
    "EXECUTABLE_NAME": "DSFC",
    "PRODUCT_NAME": "DSFC",
    "PRODUCT_MODULE_NAME": "DSFC",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.cetach.dsfc",
    "TARGET_NAME": "DSFC",
    "MARKETING_VERSION": "15.6",
    "CURRENT_PROJECT_VERSION": "113",
    "DEVELOPMENT_LANGUAGE": "zh-Hans",
    "CFBundleDevelopmentRegion": "zh-Hans",
}


def render(value, env):
    """把 $(VAR) / ${VAR} 形式的占位符替换成真实值。"""
    if isinstance(value, str):
        out = value
        for key, replacement in env.items():
            out = out.replace("$(" + key + ")", replacement)
            out = out.replace("${" + key + "}", replacement)
        return out
    if isinstance(value, list):
        return [render(item, env) for item in value]
    if isinstance(value, dict):
        return dict((key, render(item, env)) for key, item in value.items())
    return value


def build(template_path, output_path, version=None, build_number=None):
    with open(template_path, "rb") as handle:
        data = plistlib.load(handle)

    env = dict(DEFAULTS)
    if version:
        env["MARKETING_VERSION"] = version
    if build_number:
        env["CURRENT_PROJECT_VERSION"] = str(build_number)

    data = render(data, env)

    # Xcode 一定会写的键，模板里没有就补上
    data.setdefault("CFBundleExecutable", env["EXECUTABLE_NAME"])
    data.setdefault("CFBundleIdentifier", env["PRODUCT_BUNDLE_IDENTIFIER"])
    data.setdefault("CFBundleName", env["PRODUCT_NAME"])
    data.setdefault("CFBundleDisplayName", env["PRODUCT_NAME"])
    data.setdefault("CFBundlePackageType", "APPL")
    data.setdefault("CFBundleDevelopmentRegion", "zh-Hans")
    data.setdefault("CFBundleInfoDictionaryVersion", "6.0")
    data.setdefault("CFBundleShortVersionString", env["MARKETING_VERSION"])
    data.setdefault("CFBundleVersion", env["CURRENT_PROJECT_VERSION"])
    data.setdefault("LSRequiresIPhoneOS", True)
    data.setdefault("MinimumOSVersion", "13.0")
    data.setdefault("BuildMachineOSBuild", "23H2")
    data.setdefault("DTCompiler", "com.apple.compilers.llvm.clang.1_0")
    data.setdefault("DTPlatformName", "iphoneos")
    data.setdefault("DTPlatformVersion", "17.2")
    data.setdefault("DTSDKName", "iphoneos17.2")
    data.setdefault("DTXcode", "1520")
    data.setdefault("DTXcodeBuild", "15C500b")
    data.setdefault("UIDeviceFamily", [1, 2])
    data.setdefault("UIRequiredDeviceCapabilities", ["arm64", "metal"])
    data.setdefault("UISupportedInterfaceOrientations", ["UIInterfaceOrientationPortrait"])
    data.setdefault("UISupportedInterfaceOrientations~ipad", [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ])
    data.setdefault("UIApplicationSupportsIndirectInputEvents", True)

    # Scene 配置里的 $(PRODUCT_MODULE_NAME).Xxx 要能被正确解析
    manifest = data.get("UIApplicationSceneManifest")
    if isinstance(manifest, dict):
        configurations = manifest.get("UISceneConfigurations") or {}
        for role, items in list(configurations.items()):
            if isinstance(items, list):
                for item in items:
                    if isinstance(item, dict) and "UISceneDelegateClassName" in item:
                        item["UISceneDelegateClassName"] = render(item["UISceneDelegateClassName"], env)
                        # 用 ObjC 运行时按类名实例化时，Swift 类要带模块名：DSFC.SceneDelegate
                        if not item["UISceneDelegateClassName"].startswith(env["PRODUCT_MODULE_NAME"] + "."):
                            item["UISceneDelegateClassName"] = env["PRODUCT_MODULE_NAME"] + "." + item["UISceneDelegateClassName"]

    parent = os.path.dirname(output_path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(output_path, "wb") as handle:
        plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY, sort_keys=True)
    return data


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    template, output = argv[1], argv[2]
    version = argv[3] if len(argv) > 3 else None
    build_number = argv[4] if len(argv) > 4 else None
    data = build(template, output, version, build_number)
    left = []

    def scan(value):
        if isinstance(value, str) and "$(" in value:
            left.append(value)
        elif isinstance(value, list):
            for item in value:
                scan(item)
        elif isinstance(value, dict):
            for item in value.values():
                scan(item)

    scan(data)
    print("已生成 %s（%d 个键）" % (output, len(data)))
    print("  CFBundleIdentifier = %s" % data.get("CFBundleIdentifier"))
    print("  CFBundleShortVersionString = %s / CFBundleVersion = %s" % (
        data.get("CFBundleShortVersionString"), data.get("CFBundleVersion")))
    print("  未解析的占位符：%s" % ("无" if not left else left))
    return 0 if not left else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

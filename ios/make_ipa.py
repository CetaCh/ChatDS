#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Xcode 编译好的 DSFC.app 用 ad-hoc 签名（ldid -S）并打包成 DSFC.ipa。

为什么单独一个脚本
    ldid 是 Mac / macOS 上的命令行工具，本机（Windows）无法运行任何外部 exe，
    所以这一步在 Mac 上执行；如果本机装了 WSL 并被允许运行，也可以跑。

用法（Mac 上）：
    # 1) 构建（不签名）
    xcodebuild -project ios/DSFC.xcodeproj -scheme DSFC -configuration Release \
               -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO

    # 2) 打包 + ad-hoc 签名（越狱设备 / 带 ldid 的自签工具链可直接安装）
    python3 ios/make_ipa.py build/Build/Products/Release-iphoneos/DSFC.app

    # 只打包不签名
    python3 ios/make_ipa.py <app> --no-sign

    # 指定输出
    python3 ios/make_ipa.py <app> -o dist/DSFC-15.6.ipa

签名之后才会有 _CodeSignature/CodeResources，否则 iOS 拒绝安装。
"""

import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import package_ipa  # noqa: E402

APP_NAME = "DSFC"


def find_ldid():
    for candidate in ("ldid", "/opt/homebrew/bin/ldid", "/usr/local/bin/ldid", "/usr/bin/ldid"):
        path = shutil.which(candidate) if os.sep not in candidate else candidate
        if path and os.path.isfile(path):
            return path
    return None


def sign(app_dir, entitlements=None):
    ldid = find_ldid()
    if not ldid:
        print("找不到 ldid，跳过签名。")
        print("安装方式：brew install ldid   （或下载 procursus 的 ldid）")
        return False
    command = [ldid, "-S"]
    if entitlements and os.path.isfile(entitlements):
        command = [ldid, "-S" + entitlements]
    command.append(os.path.join(app_dir, APP_NAME))
    print("签名：%s" % " ".join(command))
    result = subprocess.call(command)
    if result != 0:
        print("ldid 返回 %d，签名失败" % result)
        return False
    return True


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    app = argv[1]
    output = os.path.join(HERE, "dist", APP_NAME + ".ipa")
    entitlements = None
    do_sign = "--no-sign" not in argv
    for index, item in enumerate(argv):
        if item in ("-o", "--output") and index + 1 < len(argv):
            output = argv[index + 1]
        if item == "--entitlements" and index + 1 < len(argv):
            entitlements = argv[index + 1]

    if not os.path.isdir(app):
        print("找不到 app：%s" % app)
        return 1
    if package_ipa.selfcheck() != 0:
        print("工程自检未通过")
        return 1

    package_ipa.build_app(app)
    if do_sign:
        if not sign(app, entitlements):
            print("提示：未签名产物只能用于研究，装到真机上需要签名（自签证书或 ldid+越狱）。")

    parent = os.path.dirname(output)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    package_ipa.make_ipa(app, output)
    print("完成：%s" % output)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

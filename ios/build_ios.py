#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 ChatDS-15.4（安卓源码）的网页外壳移植成 iOS 原生外壳后的构建说明 & 自动化校验。

用法：
    python build_ios.py            # 跑全部自检 + 打印 Mac 构建命令
    python build_ios.py --test     # 额外跑 Node 层的桥接 / Swift 逻辑测试

说明：本机（Windows）没有 Xcode / Swift 工具链，编译 Mach-O 必须在 Mac 上完成，
      因此这里只负责资源生成、源码校验、以及最终 .ipa 的组装。
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import package_ipa  # noqa: E402


def run_node(script):
    path = os.path.join(HERE, script)
    if not os.path.exists(path):
        print('[SKIP] 找不到 %s' % script)
        return None
    try:
        proc = subprocess.run(['node', path], cwd=HERE, capture_output=True)
    except OSError as exc:
        print('[SKIP] 无法运行 node：%s' % exc)
        return None
    text = proc.stdout.decode('utf-8', 'replace') + proc.stderr.decode('utf-8', 'replace')
    for line in text.strip().splitlines():
        print('    ' + line)
    return proc.returncode


def main():
    parser = argparse.ArgumentParser(description='DSFC iOS 构建辅助脚本')
    parser.add_argument('--test', action='store_true', help='额外运行 Node 层单元测试')
    args = parser.parse_args()

    print('== 1. 源码与资源自检 ==')
    ok = package_ipa.selfcheck() == 0
    if not ok:
        print('\n自检未通过，已停止。')
        return 1

    if args.test:
        print('\n== 2. Node 层测试 ==')
        code_bridge = run_node('test_ios_bridge.js')
        code_swift = run_node('test_swift_logic.js')
        if code_bridge not in (0, None) or code_swift not in (0, None):
            print('\n有测试未通过。')
            return 1
    else:
        print('\n（加 --test 可运行 Node 层单元测试）')

    print('\n== 3. 在 Mac 上构建 ==')
    print('  xcodebuild -project ios/DSFC.xcodeproj -scheme DSFC -configuration Release \\')
    print('             -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO')
    print('  python3 ios/package_ipa.py --app build/Build/Products/Release-iphoneos/DSFC.app')
    print('\n产物：ios/dist/DSFC.ipa（另附 DSFC.app.zip），交给签名工具或 Xcode 安装。')
    return 0


if __name__ == '__main__':
    sys.exit(main())

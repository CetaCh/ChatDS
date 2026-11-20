# -*- coding: utf-8 -*-
"""在本机预打包：生成 Payload/DSFC.app（图标、启动图、网页、Info.plist 全齐），
压成可上传的 ipa。本机没有 Swift/Mach-O 编译器，包内暂缺 DSFC 可执行文件，
CI 或 Mac 编译后由 package_ipa.py 补上。输出字节固定，不会每次不一样。"""
import io
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_infoplist  # noqa: E402
import package_ipa  # noqa: E402
from PIL import Image  # noqa: E402

APP = package_ipa.PROJECT
RES = os.path.join(APP, "Resources")
ASSETS_SRC = os.path.join(RES, "Assets.xcassets")
DIST = os.path.join(HERE, "dist")
STAGE = os.path.join(HERE, "build", "stage")
APP_NAME = "DSFC"

ICON = os.path.join(ASSETS_SRC, "AppIcon.appiconset", "AppIcon-1024.png")
LAUNCH = os.path.join(ASSETS_SRC, "LaunchLogo.imageset", "LaunchLogo@3x.png")

ICON_SIZES = [
    ("AppIcon-20", 20), ("AppIcon-20@2x", 40), ("AppIcon-20@3x", 60),
    ("AppIcon-29", 29), ("AppIcon-29@2x", 58), ("AppIcon-29@3x", 87),
    ("AppIcon-40", 40), ("AppIcon-40@2x", 80), ("AppIcon-40@3x", 120),
    ("AppIcon-60@2x", 120), ("AppIcon-60@3x", 180),
    ("AppIcon-76", 76), ("AppIcon-76@2x", 152), ("AppIcon-83.5@2x", 167),
    ("AppIcon-1024", 1024),
]


def build_stage():
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    app_dir = os.path.join(STAGE, "Payload", APP_NAME + ".app")
    logs = []

    icon_set = os.path.join(app_dir, "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(icon_set)
    icon = Image.open(ICON).convert("RGB")
    for name, px in ICON_SIZES:
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(icon_set, name + ".png"), "PNG")
    logs.append("图标 %d 张（20~1024，无透明通道）" % len(ICON_SIZES))

    launch_set = os.path.join(app_dir, "Assets.xcassets", "LaunchLogo.imageset")
    os.makedirs(launch_set)
    launch = Image.open(LAUNCH).convert("RGBA")
    for scale, px in ((1, 80), (2, 160), (3, 240)):
        launch.resize((px, px), Image.LANCZOS).save(
            os.path.join(launch_set, "LaunchLogo@%dx.png" % scale), "PNG")
    logs.append("启动图 1x/2x/3x")

    shutil.copytree(os.path.join(RES, "www"), os.path.join(app_dir, "www"))
    pages = sum(len(files) for _, _, files in os.walk(os.path.join(app_dir, "www")))
    logs.append("网页 %d 个文件" % pages)

    data = build_infoplist.build(os.path.join(APP, "Info.plist"),
                                 os.path.join(app_dir, "Info.plist"), "15.6", "113")
    logs.append("Info.plist %s / %s / UIDeviceFamily=%s" % (
        data["CFBundleIdentifier"], data["CFBundleShortVersionString"], data["UIDeviceFamily"]))

    loc = os.path.join(app_dir, "zh-Hans.lproj")
    os.makedirs(loc)
    with io.open(os.path.join(loc, "InfoPlist.strings"), "w", encoding="utf-8") as fh:
        fh.write(u'"CFBundleDisplayName" = "DS-FC";\n"CFBundleName" = "DS-FC";\n')
    logs.append("本地化 zh-Hans")
    return app_dir, logs


def main():
    app_dir, logs = build_stage()
    os.makedirs(DIST, exist_ok=True)
    ipa = os.path.join(DIST, "DSFC-未签名.ipa")
    package_ipa.make_ipa(app_dir, ipa)
    logs.append("ipa：%s" % ipa)
    print("\n".join(logs))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_icons.py — 用安卓版图标生成 iOS 所需的全部图标 / 启动图资源

输入：app/src/main/res/mipmap-xxxhdpi/ic_launcher.png（192×192，黑底圆角方块 + 白色对话气泡）
输出：ios/DSFC/Resources/Assets.xcassets 下的
    AppIcon.appiconset              单尺寸 1024（iOS 14+ 通用图标，本工程只出这一组）
    SplashLogo.imageset             启动画面中央的小图标（100×100 @1x/2x/3x）
    LaunchBackground.colorset       启动画面底色（跟随系统深浅色）

处理要点：
  * App Store 要求图标不带 alpha 通道，且不要自带圆角（圆角由系统裁切），
    所以把安卓图标四角的透明区域用底色（黑）铺满，再输出 RGB PNG。
  * 启动图按安卓的用法放大显示：先做「向外填充」让圆角边缘补齐，
    否则 iOS 的大圆角会把四角裁掉、露出白色底。
"""

import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "src", "ChatDS-15.4-src", "app", "src", "main",
                   "res", "mipmap-xxxhdpi", "ic_launcher.png")
ASSETS = os.path.join(HERE, "DSFC", "Resources", "Assets.xcassets")

DARK_BG = (0, 0, 0)


def write_json(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def flatten(icon, background=DARK_BG):
    """把透明区域铺成底色，返回 RGB 图。"""
    canvas = Image.new("RGBA", icon.size, background + (255,))
    canvas.alpha_composite(icon.convert("RGBA"))
    return canvas.convert("RGB")


def square_icon(icon):
    """
    把"圆角方块"图标还原成直角方形：每一行/列不再做遮罩，
    只在像素本身就是内容的地方保留，圆角处用最近的非透明像素补齐，
    这样 iOS 自己裁圆角时不会露出底色。
    """
    w, h = icon.size
    px = icon.load()
    solid = icon.convert("RGBA").copy()
    # 先把半透明边缘压成实色（黑底上的抗锯齿像素）
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a >= 128:
                px[x, y] = (r, g, b, 255)
            else:
                px[x, y] = (0, 0, 0, 0)
    for y in range(h):
        for x in range(w):
            if px[x, y][3] != 0:
                continue
            # 找同一行里最近的不透明像素（左右），找不到就用同列的上/下
            neighbours = []
            for dx in range(1, w):
                if x - dx >= 0 and px[x - dx, y][3] != 0:
                    neighbours.append(px[x - dx, y])
                    break
            for dx in range(1, w):
                if x + dx < w and px[x + dx, y][3] != 0:
                    neighbours.append(px[x + dx, y])
                    break
            for dy in range(1, h):
                if y - dy >= 0 and px[x, y - dy][3] != 0:
                    neighbours.append(px[x, y - dy])
                    break
            for dy in range(1, h):
                if y + dy < h and px[x, y + dy][3] != 0:
                    neighbours.append(px[x, y + dy])
                    break
            if neighbours:
                px[x, y] = neighbours[0]
            else:
                px[x, y] = (0, 0, 0, 255)
    del solid
    return icon


def make_appicon(icon):
    size = 1024
    flat = flatten(icon)
    # 直接用高质量重采样放大：黑底不需要边缘处理
    big = flat.resize((size, size), Image.LANCZOS)
    big = big.convert("RGB")
    out_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(out_dir, exist_ok=True)
    big.save(os.path.join(out_dir, "AppIcon-1024.png"), "PNG", optimize=True)
    write_json(os.path.join(out_dir, "Contents.json"), """{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""")
    return size


def make_splash(icon):
    base = square_icon(icon.convert("RGBA"))
    base = base.resize((300, 300), Image.LANCZOS)
    out_dir = os.path.join(ASSETS, "SplashLogo.imageset")
    os.makedirs(out_dir, exist_ok=True)
    entries = []
    for scale, px in ((1, 100), (2, 200), (3, 300)):
        name = "SplashLogo@%dx.png" % scale
        base.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name), "PNG", optimize=True)
        entry = {
            "filename": name,
            "idiom": "universal",
            "scale": "%dx" % scale,
        }
        entries.append(entry)
    import json
    write_json(os.path.join(out_dir, "Contents.json"), json.dumps(
        {"images": entries, "info": {"author": "xcode", "version": 1}},
        indent=2, ensure_ascii=False) + "\n")


def make_launch_logo():
    """
    启动画面用的图：透明背景，只保留图标本身的黑色方块 + 白色气泡。
    UILaunchScreen 会把这张图按原尺寸居中显示在 LaunchBackground 底色上，
    浅色模式下底色是白色，所以图片里必须是黑底圆角方块本身（不能是透明角）。
    """
    out_dir = os.path.join(ASSETS, "LaunchLogo.imageset")
    os.makedirs(out_dir, exist_ok=True)
    base = square_icon(Image.open(SRC).convert("RGBA"))
    base = base.resize((300, 300), Image.LANCZOS)
    import json
    entries = []
    for scale, px in ((1, 80), (2, 160), (3, 240)):
        name = "LaunchLogo@%dx.png" % scale
        base.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name), "PNG", optimize=True)
        entries.append({"filename": name, "idiom": "universal", "scale": "%dx" % scale})
    write_json(os.path.join(out_dir, "Contents.json"), json.dumps(
        {"images": entries, "info": {"author": "xcode", "version": 1}},
        indent=2, ensure_ascii=False) + "\n")


def make_background_color():
    out_dir = os.path.join(ASSETS, "LaunchBackground.colorset")
    os.makedirs(out_dir, exist_ok=True)
    write_json(os.path.join(out_dir, "Contents.json"), """{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "1.000",
          "green" : "1.000",
          "red" : "1.000"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0.090",
          "green" : "0.082",
          "red" : "0.082"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""")


def main():
    if not os.path.exists(SRC):
        print("找不到安卓图标：%s" % SRC)
        return 1
    icon = Image.open(SRC).convert("RGBA")
    print("源图标：%s %s" % (SRC, icon.size))
    size = make_appicon(icon)
    print("已生成 AppIcon %dx%d（无 alpha）" % (size, size))
    make_splash(icon)
    print("已生成 SplashLogo @1x/@2x/@3x")
    make_launch_logo()
    print("已生成 LaunchLogo @1x/@2x/@3x")
    make_background_color()
    print("已生成 LaunchBackground 颜色资源")
    write_json(os.path.join(ASSETS, "Contents.json"), """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())

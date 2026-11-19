#!/usr/bin/env python3
"""打印 AppIcon.appiconset 需要的文件名与像素尺寸（tab 分隔）。

用法：python3 scripts-appicon.py <AppIcon.appiconset 目录>
如果模板 Contents.json 里没有 filename（Tauri 默认模板的情况），
会按 iOS 标准图标集补全 Contents.json，并输出对应的尺寸。
"""
import json
import os
import sys

d = sys.argv[1]
path = os.path.join(d, "Contents.json")
try:
    conf = json.load(open(path, encoding="utf-8"))
except Exception:
    conf = {}

rows = []
for im in conf.get("images", []):
    fn = im.get("filename")
    if not fn:
        continue
    size = im.get("size", "1024x1024")
    scale = im.get("scale", "1x")
    try:
        w = float(size.split("x")[0]) * float(scale.rstrip("x"))
    except Exception:
        continue
    rows.append((fn, int(round(w))))

if not rows:
    # 标准 iPhone 图标集（Contents.json 没有 filename 时使用）
    spec = [
        ("Icon-20@2x.png", 40, "20x20", "2x", "iphone"),
        ("Icon-20@3x.png", 60, "20x20", "3x", "iphone"),
        ("Icon-29@2x.png", 58, "29x29", "2x", "iphone"),
        ("Icon-29@3x.png", 87, "29x29", "3x", "iphone"),
        ("Icon-40@2x.png", 80, "40x40", "2x", "iphone"),
        ("Icon-40@3x.png", 120, "40x40", "3x", "iphone"),
        ("Icon-60@2x.png", 120, "60x60", "2x", "iphone"),
        ("Icon-60@3x.png", 180, "60x60", "3x", "iphone"),
        ("Icon-1024.png", 1024, "1024x1024", "1x", "ios-marketing"),
    ]
    conf = {"images": [], "info": {"version": 1, "author": "xcode"}}
    for fn, px, size, scale, idiom in spec:
        conf["images"].append({"filename": fn, "idiom": idiom, "scale": scale, "size": size})
        rows.append((fn, px))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(conf, f, indent=2)
        f.write("\n")

for fn, px in rows:
    print(f"{fn}\t{px}")

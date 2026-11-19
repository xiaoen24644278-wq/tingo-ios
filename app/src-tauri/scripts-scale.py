#!/usr/bin/env python3
"""把 PNG 缩放到指定方形尺寸（保留 alpha）。

用法：python3 scripts-scale.py <源图> <目标> <像素>
用于 Android 各密度启动图标（CI 上没有稳定的 ffmpeg/ImageMagick）。
"""
import sys

from PIL import Image

src, dst, px = sys.argv[1], sys.argv[2], int(sys.argv[3])
Image.open(src).convert("RGBA").resize((px, px), Image.LANCZOS).save(dst)

#!/usr/bin/env python3
"""把 iOS 的 LaunchScreen.storyboard 背景改成 #0B0E17，和前端启动遮罩同色。

用法：python3 scripts-launchscreen.py <LaunchScreen.storyboard>
"""
import re
import sys

BLACK = ('<color key="backgroundColor" red="0.043137254901960784" '
         'green="0.054901960784313725" blue="0.09019607843137255" '
         'alpha="1" colorSpace="custom" customColorSpace="sRGB"/>')

path = sys.argv[1]
s = open(path, encoding="utf-8").read()

new, n = re.subn(r'<color key="backgroundColor"[^/]*/>', BLACK, s)
if n == 0:
    # 模板里没有背景色节点：给根 view 补一个
    new, n = re.subn(r'(<view key="view"[^>]*>)', r'\1\n        ' + BLACK, s, count=1)

open(path, "w", encoding="utf-8").write(new)
print(f"LaunchScreen 背景色已改为 #0B0E17（{n} 处）")

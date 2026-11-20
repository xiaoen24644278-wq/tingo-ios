#!/usr/bin/env python3
"""给 Tauri 生成的 MainActivity.kt 补一段「启动时请求麦克风权限」。

Android 的运行时权限只能在 Activity 里申请，TingoAudio 是普通 object 拿不到结果回调，
所以在 Activity.onCreate 里发起一次申请即可（系统会弹授权框）。

用法：python3 scripts-micperm.py <MainActivity.kt>
"""
import re
import sys

PATH = sys.argv[1]
src = open(PATH, encoding="utf-8").read()

MARK = "TingoMicPermission"
if MARK in src:
    print("MainActivity：已包含权限申请代码，跳过")
    raise SystemExit(0)

# 需要的 import
imports = [
    "import android.Manifest",
    "import android.content.pm.PackageManager",
]
added = []
for imp in imports:
    if imp not in src:
        # 插到 package 声明之后
        m = re.search(r"^package .*\n", src, re.M)
        if m:
            src = src[: m.end()] + "\n" + imp + "\n" + src[m.end():]
        else:
            src = imp + "\n" + src
        added.append(imp)

REQUEST = """
    // TingoMicPermission：首次启动就申请录音权限，避免用户点录音才发现没授权
    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1001)
    }
"""

# 在 onCreate 的 super.onCreate(...) 之后插入
m = re.search(r"(super\.onCreate\([^)]*\))", src)
if m:
    src = src[: m.end()] + "\n" + REQUEST + src[m.end():]
    print("MainActivity：已在 onCreate 里加入麦克风权限申请")
else:
    # 没有 onCreate 就补一个
    cls = re.search(r"class\s+MainActivity\s*:\s*[A-Za-z]+\([^)]*\)\s*\{", src)
    if cls:
        ctor = """
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
""" + REQUEST + """    }
"""
        src = src[: cls.end()] + ctor + src[cls.end():]
        print("MainActivity：已新增 onCreate 并加入权限申请")
    else:
        print("MainActivity：没识别出类结构，未修改")
        raise SystemExit(0)

open(PATH, "w", encoding="utf-8").write(src)

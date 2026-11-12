#!/usr/bin/env python3
"""End-to-end renderer check: opens every fixture in the real app (Perlustra --probe) and
asserts which engine rendered it. Usage: scripts/verify-renderers.py [path/to/Perlustra.app]"""
import json, subprocess, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "build/app.noindex/Perlustra.app"
binary = app / "Contents/MacOS/Perlustra"

# file (relative to fixtures/) → expected engine; "none" means the failure page is shown.
EXPECT = {
    "text/中文-utf8.txt": "TextKit", "text/中文-gbk.txt": "TextKit", "text/中文-gb18030.txt": "TextKit",
    "text/big5.txt": "TextKit", "text/shift_jis.txt": "TextKit", "text/utf16le-bom.txt": "TextKit",
    "text/empty.txt": "TextKit", "text/crlf-windows.txt": "TextKit", "text/large-60mb.log": "TextKit",
    "code/hello.py": "TextKit", "code/app.js": "TextKit", "code/types.ts": "TextKit", "code/main.go": "TextKit",
    "code/lib.rs": "TextKit", "code/Main.java": "TextKit", "code/query.sql": "TextKit", "code/deploy.sh": "TextKit",
    "code/config.yaml": "TextKit", "code/settings.toml": "TextKit", "code/app.ini": "TextKit", "code/page.xml": "TextKit",
    "code/style.css": "TextKit", "code/main.c": "TextKit", "code/changes.diff": "TextKit", "code/Makefile": "TextKit",
    "code/Dockerfile": "TextKit", "code/server.log": "TextKit", "code/TextRenderer.swift": "TextKit",
    "docs/README.md": "WebKit", "docs/page.html": "WebKit", "docs/outline.pdf": "PDFKit",
    "data/config.json": "JSON", "data/minified.json": "JSON", "data/events.jsonl": "TextKit", "data/broken.json": "TextKit",
    "data/binary.plist": "Plist", "data/xml.plist": "Plist",
    "data/demo.sqlite": "SQLite",
    "data/sales-utf8.csv": "表格", "data/sales-gbk.csv": "表格", "data/table.tsv": "表格", "data/large-200k.csv": "表格",
    "office/sales.xlsx": "表格", "office/stock.ods": "表格", "office/report-styled.xlsx": "表格", "office/charts.xlsx": "表格", "office/rich-text.xlsx": "表格",
    "images/photo.jpg": "ImageIO", "images/exif-camera.jpg": "ImageIO", "images/orientation-6.jpg": "ImageIO",
    "images/transparent.png": "ImageIO", "images/pixel-art.png": "ImageIO", "images/animated.gif": "ImageIO",
    "images/multipage.tiff": "ImageIO", "images/photo.webp": "ImageIO", "images/photo.bmp": "ImageIO",
    "images/icon.ico": "ImageIO", "images/photo.heic": "ImageIO", "images/photo.avif": "ImageIO",
    "images/panorama-20000px.png": "ImageIO", "images/vector.svg": "WebKit",
    "media/h264-aac.mp4": "AVFoundation", "media/hevc.mov": "AVFoundation", "media/tone.mp3": "AVFoundation",
    "media/tone.flac": "AVFoundation", "media/tone.wav": "AVFoundation",
    "media/h264-ac3.mkv": "mpv", "media/vp9-opus.webm": "mpv", "media/mpeg4.avi": "mpv", "media/sample.flv": "mpv",
    "media/tone.opus": "mpv",
    "archives/sample.zip": "libarchive", "archives/sample.7z": "libarchive", "archives/sample.tar": "libarchive",
    "archives/sample.tar.gz": "libarchive", "archives/sample.tar.xz": "libarchive", "archives/sample.iso": "libarchive",
    "fonts/Arial.ttf": "CoreText", "fonts/Arial.woff": "CoreText", "fonts/NewYork.ttf": "CoreText", "fonts/Songti.ttc": "CoreText",
    "office/sample.docx": "QuickLook", "office/sample.doc": "QuickLook", "office/sample.rtf": "QuickLook",
    "office/sample.odt": "QuickLook", "office/from-keynote.pptx": "QuickLook", "office/from-numbers.xlsx": "表格",
    "iwork/sample.pages": "iWork", "iwork/sample.key": "iWork", "iwork/sample.numbers": "表格",
    "edge/truncated.png": "ImageIO", "edge/garbage.pdf": "Hex", "edge/not-a-zip.zip": "Hex", "edge/truncated.mp4": "none",
    "edge/really-a-png.txt": "ImageIO", "edge/really-a-pdf.jpg": "PDFKit", "edge/no-extension": "JSON",
    "edge/unknown.xyz": "Hex", "edge/zero-bytes.bin": "TextKit", "edge/control-chars.txt": "Hex",
}
MISMATCH = {"edge/really-a-png.txt", "edge/really-a-pdf.jpg"}

files = [k for k in EXPECT if (root / "fixtures" / k).exists()]
missing = [k for k in EXPECT if k not in files]
proc = subprocess.run([str(binary), "--probe", *[str(root / "fixtures" / f) for f in files]],
                      capture_output=True, text=True, timeout=900)
results = {}
for line in proc.stdout.splitlines():
    try:
        d = json.loads(line)
        results[d["file"]] = d
    except json.JSONDecodeError:
        pass

# CI 机器通常没有 libmpv。此时「mpv」引擎其实是安装提示页，系统解码器能播的
# （例如 Opus）会停在 AVFoundation，截断的 mp4 也会停在安装页而不是失败页。
# 装了 mpv 的机器仍按原期望严格比对。
placeholder = "需要 mpv"
mpv_placeholder = any(d.get("engine") == "mpv" and d.get("status") == placeholder for d in results.values())
if mpv_placeholder:
    print("未加载 libmpv：安装页和系统解码器的结果按环境放行。\n")

def acceptable(path, expected, got):
    if got["engine"] == expected:
        return True
    if not mpv_placeholder:
        return False
    if expected == "mpv" and got["engine"] == "AVFoundation":
        return True
    if expected == "none" and got["engine"] == "mpv" and got.get("status") == placeholder:
        return True
    return False

ok = fail = 0
for f in files:
    d = results.get(Path(f).name)
    exp = EXPECT[f]
    good = d is not None and acceptable(f, exp, d) and (f not in MISMATCH or d["mismatch"])
    ok += good
    fail += not good
    mark = "✔" if good else "✘"
    got = "（无结果）" if d is None else f"{d['engine']}{' · 扩展名不符' if d['mismatch'] else ''}"
    print(f"{mark} {f:34} 期望 {exp:13} 实际 {got}")
print(f"\n{ok} 通过，{fail} 失败" + (f"，{len(missing)} 个样例缺失（未生成）" if missing else ""))
sys.exit(1 if fail else 0)

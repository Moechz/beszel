#!/usr/bin/env python3
"""check_assets.py — 上架前的资产静态自检（Makefile check 调用）

按 TOS 7 应用中心规范校验：
  1. assets/config.ini.in 是合法 JSON（渲染 @@VERSION@@ 等占位符后），
     且不出现与 open_path 互斥的 type 字段
  2. assets/beszelmonitor.lang 含全部 23 个语言节（真机 14 键 + 9 补充键超集，
     官方只查存在性），UTF-8 无 BOM，LF 行尾；不含 beta 字样（V11 门禁）
  3. assets/ 下所有文本资产无 CRLF / BOM
  4. 图标 SVG：XML 可解析 + viewBox + fill + path 数据非截断（下载截断实锤，坑 47）
  5. 隐私政策资产存在（C3 必备，坑 45）
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fail = 0

# 23 语超集：真机实测 14 键 + 补充 9 键（未翻译节点填英文，官方只查存在性）
REQUIRED_LANGS = ["zh-cn", "zh-hk", "en-us", "fr-fr", "de-de", "it-it", "es-es",
                  "hu-hu", "ja-jp", "ko-kr", "pl-pl", "ru-ru", "tr-tr", "pt-pt",
                  "ar-sa", "cs-cz", "he-il", "id-id", "nb-no", "nl-nl",
                  "sv-se", "th-th", "vi-vn"]

# ---------- 1. config.ini.in ----------
raw = (ROOT / "assets/config.ini.in").read_text(encoding="utf-8")
rendered = (raw.replace("@@VERSION@@", "0.0.0")
              .replace("@@PUBLISHER@@", "x")
              .replace("@@PLATFORM@@", "x86_64"))
try:
    json.loads(rendered)
    print("config.ini.in: JSON 合法 ✓")
except Exception as e:  # noqa: BLE001
    print(f"config.ini.in: JSON 非法 ✗ ({e})")
    fail = 1
# open_path（新标签页）与 type 字段互斥，混用即驳（规范 §打开方式）
if '"type"' in rendered:
    print("config.ini.in: 出现 type 字段（与 open_path 互斥） ✗")
    fail = 1

# ---------- 2. lang ----------
lang_path = ROOT / "assets/beszelmonitor.lang"
data = lang_path.read_bytes()
if data.startswith(b"\xef\xbb\xbf"):
    print("lang: 含 BOM ✗")
    fail = 1
text = data.decode("utf-8")
found = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", text, re.M)
missing = [t for t in REQUIRED_LANGS if t not in found]
if missing:
    print(f"lang: 缺少语言节 ✗ {missing}")
    fail = 1
else:
    print(f"lang: 23 语言超集齐全 ✓（共 {len(found)} 节）")
# V11 门禁：lang 不得出现 beta 字样
if re.search(r"\bbeta\b", text, re.I):
    print("lang: 含 'beta' 字样（V11 驳回红线） ✗")
    fail = 1

# ---------- 3. CRLF / BOM 扫描 ----------
for p in sorted((ROOT / "assets").rglob("*")):
    if not p.is_file() or p.suffix not in {".ini", ".in", ".lang", ".conf",
                                           ".service", ".env", ".sh", ".html",
                                           ".js", ".css", ".svg"}:
        continue
    b = p.read_bytes()
    rel = p.relative_to(ROOT)
    if b.startswith(b"\xef\xbb\xbf"):
        print(f"{rel}: 含 BOM ✗")
        fail = 1
    if b"\r\n" in b or b"\r" in b:
        print(f"{rel}: 含 CR ✗")
        fail = 1
if fail == 0:
    print("行尾/BOM: 全部合规 ✓")

# ---------- 4. 图标 SVG（坑 47：下载截断会渲染成灰白块） ----------
icon = ROOT / "assets/images/icons/beszelmonitor.svg"
try:
    root = ET.parse(icon).getroot()
    issues = []
    if not root.get("viewBox"):
        issues.append("缺 viewBox")
    svg_text = icon.read_text(encoding="utf-8")
    if 'fill=' not in svg_text:
        issues.append("缺 fill 颜色")
    # path d 数据截断启发式：合法路径至少几十字符，中途中断的 path 明显过短
    for m in re.finditer(r'<path\b[^>]*\bd="([^"]+)"', svg_text):
        if len(m.group(1)) < 20:
            issues.append(f"疑似截断的 path（d 仅 {len(m.group(1))} 字符）")
            break
    if issues:
        print(f"图标: {issues} ✗")
        fail = 1
    else:
        print("图标: SVG 可解析 + viewBox/fill/path 完整 ✓")
except ET.ParseError as e:
    print(f"图标: XML 解析失败（疑似截断） ✗ ({e})")
    fail = 1

# ---------- 5. 隐私政策（坑 45：C3 必备资产） ----------
pp = ROOT / "assets/privacy-policy.html"
if pp.is_file() and pp.stat().st_size > 1000:
    print("隐私政策: assets/privacy-policy.html 存在 ✓")
else:
    print("隐私政策: 缺失或过小（C3 一票拒） ✗")
    fail = 1

sys.exit(fail)

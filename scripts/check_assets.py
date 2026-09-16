#!/usr/bin/env python3
"""check_assets.py — 上架前的资产静态自检（Makefile check 调用）

按 TOS 7 应用中心规范校验：
  1. assets/config.ini.in 是合法 JSON（渲染 @@VERSION@@ 等占位符后）
  2. assets/beszelmonitor.lang 含全部 14 个必需语言节，UTF-8 无 BOM，LF 行尾
  3. assets/ 下所有文本资产无 CRLF / BOM
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fail = 0

REQUIRED_LANGS = ["zh-cn", "zh-hk", "en-us", "fr-fr", "de-de", "it-it", "es-es",
                  "hu-hu", "ja-jp", "ko-kr", "pl-pl", "ru-ru", "tr-tr", "pt-pt"]

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
    print(f"lang: 14 语言齐全 ✓（共 {len(found)} 节）")

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

sys.exit(fail)

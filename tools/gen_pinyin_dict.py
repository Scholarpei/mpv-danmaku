#!/usr/bin/env python3
"""生成 dicts/pinyin_chars.lua（pakku 式拼音谐音合并用字典）。

数据源: mozillazg/pinyin-data 的 pinyin.txt (MIT License)
处理: NFD 去声调 -> 去重 -> 每字至多保留 2 个读音 -> GB2312 字集过滤（与 pakku 覆盖面一致）
输出: Lua 表 `return { ["行"] = "xing,hang", ... }`（UTF-8 无 BOM）

用法: PYTHON_BASIC_REPL=1 python tools/gen_pinyin_dict.py [--input 本地pinyin.txt]
若本地 pinyin.txt 不存在则自动下载。
"""

import argparse
import io
import sys
import unicodedata
import urllib.request
from pathlib import Path

URL = "https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt"
MAX_READINGS = 2  # pakku 每字至多 2 个读音
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "dicts" / "pinyin_chars.lua"

# 验证 fixture 依赖的字必须在表内
REQUIRED = ["泪", "累", "目", "行", "哈"]


def strip_tone(s: str) -> str:
    # NFD 分解后去掉组合声调符号（Mn 类）
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def load_lines(local: Path | None) -> list[str]:
    if local and local.exists():
        return local.read_text(encoding="utf-8").splitlines()
    print(f"下载 {URL} ...")
    with urllib.request.urlopen(URL, timeout=60) as resp:
        return io.TextIOWrapper(resp, encoding="utf-8").read().splitlines()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, default=ROOT / "tools" / "pinyin.txt",
                    help="本地 pinyin.txt 缓存路径（存在则免下载）")
    args = ap.parse_args()

    table = {}
    for line in load_lines(args.input):
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        cp_str, readings_str = line.split(":", 1)
        cp = int(cp_str.strip().replace("U+", ""), 16)
        ch = chr(cp)
        # GB2312 字集过滤（6763 常用汉字，与 pakku 覆盖面一致）
        try:
            ch.encode("gb2312")
        except UnicodeEncodeError:
            continue
        seen, readings = set(), []
        for raw in readings_str.split():
            toneless = strip_tone(raw).lower()
            if toneless and toneless not in seen:
                seen.add(toneless)
                readings.append(toneless)
            if len(readings) >= MAX_READINGS:
                break
        if readings:
            table[ch] = ",".join(readings)

    missing = [c for c in REQUIRED if c not in table]
    if missing:
        print(f"错误: 必需字缺失 {missing}")
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8", newline="\n") as f:
        f.write("-- 汉字->拼音(无声调)映射表，由 tools/gen_pinyin_dict.py 生成\n")
        f.write("-- 数据源: mozillazg/pinyin-data (MIT)；每字至多 2 个读音，GB2312 字集\n")
        f.write("return {\n")
        for ch in sorted(table, key=ord):
            lua_ch = ch.replace("\\", "\\\\").replace('"', '\\"')
            lua_py = table[ch].replace("\\", "\\\\").replace('"', '\\"')
            f.write(f'  ["{lua_ch}"] = "{lua_py}",\n')
        f.write("}\n")

    print(f"完成: {OUT} ({len(table)} 字)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

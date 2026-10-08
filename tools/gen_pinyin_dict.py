#!/usr/bin/env python3
"""生成 dicts/pinyin_chars.lua 与 dicts/pinyin_chars_ext.lua（pakku 式拼音谐音合并用字典）。

数据源: mozillazg/pinyin-data 的 pinyin.txt (MIT License)
  行格式: `U+4E00: yī,yī,yī  # 一`（读音逗号分隔，行尾 `# 字形` 为注释）
处理: 剥离行尾注释 → NFD 去声调 → 按逗号切分读音 → 去重 → 每字至多 2 个读音
输出（UTF-8 无 BOM，Lua 表 `return { ["行"] = "xing,hang", ... }`）:
  pinyin_chars.lua       GB2312 字集（6763 常用字，与 pakku 覆盖面一致）
  pinyin_chars_ext.lua   补充表：GBK 有而 GB2312 无的字（咲、凪、雫等日式汉字、
                        繁体字与 GBK 扩展字，约 14k 字）。运行时由 pakku_merge
                        叠加进主表；删除该文件即回退 GB2312 覆盖面，不影响其余功能

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
OUT_MAIN = ROOT / "dicts" / "pinyin_chars.lua"
OUT_EXT = ROOT / "dicts" / "pinyin_chars_ext.lua"

# 验证 fixture 依赖的字必须在表内
REQUIRED_MAIN = ["泪", "累", "目", "行", "哈"]
REQUIRED_EXT = ["咲", "凪", "雫"]


def strip_tone(s: str) -> str:
    # NFD 分解后去掉组合声调符号（Mn 类）
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def in_charset(ch: str, codec: str) -> bool:
    try:
        ch.encode(codec)
    except UnicodeEncodeError:
        return False
    return True


def load_lines(local: Path | None) -> list[str]:
    if local and local.exists():
        return local.read_text(encoding="utf-8").splitlines()
    print(f"下载 {URL} ...")
    with urllib.request.urlopen(URL, timeout=60) as resp:
        return io.TextIOWrapper(resp, encoding="utf-8").read().splitlines()


def parse_readings(readings_str: str) -> list[str]:
    """`yī,yī,yī  # 一` 右值 → 去声调去重、至多 MAX_READINGS 个读音。"""
    # 只留行尾 `#` 注释之前的部分（无注释的行原样），再按逗号切分
    readings_str = readings_str.split("#", 1)[0]
    seen, readings = set(), []
    for raw in readings_str.split(","):
        toneless = strip_tone(raw.strip().lower())
        if toneless and toneless not in seen:
            seen.add(toneless)
            readings.append(toneless)
        if len(readings) >= MAX_READINGS:
            break
    return readings


def write_table(out: Path, table: dict[str, str], header_lines: list[str]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as f:
        for line in header_lines:
            f.write(f"-- {line}\n")
        f.write("return {\n")
        for ch in sorted(table, key=ord):
            lua_ch = ch.replace("\\", "\\\\").replace('"', '\\"')
            lua_py = table[ch].replace("\\", "\\\\").replace('"', '\\"')
            f.write(f'  ["{lua_ch}"] = "{lua_py}",\n')
        f.write("}\n")
    print(f"完成: {out} ({len(table)} 字)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, default=ROOT / "tools" / "pinyin.txt",
                    help="本地 pinyin.txt 缓存路径（存在则免下载）")
    args = ap.parse_args()

    main_table, ext_table = {}, {}
    for line in load_lines(args.input):
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        cp_str, readings_str = line.split(":", 1)
        ch = chr(int(cp_str.strip().replace("U+", ""), 16))
        readings = parse_readings(readings_str)
        if not readings:
            continue
        if in_charset(ch, "gb2312"):
            main_table[ch] = ",".join(readings)
        elif in_charset(ch, "gbk"):
            ext_table[ch] = ",".join(readings)

    for required, table, name in ((REQUIRED_MAIN, main_table, "主表"),
                                  (REQUIRED_EXT, ext_table, "补充表")):
        missing = [c for c in required if c not in table]
        if missing:
            print(f"错误: {name}必需字缺失 {missing}")
            return 1

    write_table(OUT_MAIN, main_table, [
        "汉字->拼音(无声调)映射表，由 tools/gen_pinyin_dict.py 生成",
        "数据源: mozillazg/pinyin-data (MIT)；每字至多 2 个读音，GB2312 字集",
    ])
    write_table(OUT_EXT, ext_table, [
        "拼音补充表（GBK 扩展字），由 tools/gen_pinyin_dict.py 生成",
        "数据源: mozillazg/pinyin-data (MIT)；每字至多 2 个读音，GBK 有而 GB2312 无的字",
        "运行时由 pakku_merge 叠加进 pinyin_chars.lua 主表，删除本文件即回退 GB2312 覆盖面",
    ])
    return 0


if __name__ == "__main__":
    sys.exit(main())

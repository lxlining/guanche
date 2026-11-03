# -*- coding: utf-8 -*-
"""生成车站/线路名的拼音映射 data/pinyin_map.json（搜索用）。

用法: python tools/gen_pinyin.py > data/pinyin_map.json
Python 零文件 I/O 约定：stdout 输出，重定向落盘。
"""
import glob
import json
import sys

from pypinyin import Style, pinyin


def collect_names():
    names = []
    for f in glob.glob("data/lines/*.json"):
        d = json.load(open(f, encoding="utf-8"))
        names.append(str(d.get("name", "")))
        names.append(str(d.get("short", "")))
        for s in d.get("stations", []):
            names.append(str(s.get("name", "")))
    doc = json.load(open("data/timetables/all.json", encoding="utf-8"))
    for tr in doc.get("trains", []):
        names.append(str(tr.get("from", "")))
        names.append(str(tr.get("to", "")))
    return [n for n in names if n]


def main():
    chars = set()
    for n in collect_names():
        for c in n:
            if "一" <= c <= "鿿":
                chars.add(c)
    table = {}
    for c in sorted(chars):
        reads = pinyin(c, style=Style.NORMAL, heteronym=True)
        uniq = sorted({r[0] for r in reads if r and r[0]})
        if uniq:
            table[c] = uniq
    json.dump(table, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    print("[gen_pinyin] %d chars" % len(table), file=sys.stderr)


if __name__ == "__main__":
    main()

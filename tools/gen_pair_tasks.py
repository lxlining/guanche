# -*- coding: utf-8 -*-
"""宽幅站对任务生成：stdin 每行一个线路 id，stdout 输出 "id <pair_idx>"。
零文件 I/O。"""
import json
import sys

for lid in sys.stdin.read().split():
    lid = lid.strip()
    if not lid or "/" in lid or "\\" in lid or ".." in lid:
        continue
    try:
        d = json.load(open("data/lines/%s.json" % lid, encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        continue
    for k in range(len(d.get("stations", [])) - 1):
        print("%s %d" % (lid, k))

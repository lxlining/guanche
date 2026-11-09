# -*- coding: utf-8 -*-
"""站级补抓任务生成：stdin 每行一个线路 id，stdout 输出 "id s<k>" 任务行。
同线内 8km 内的站去重（短城际站密集，全抓会大量重叠）。零文件 I/O。"""
import json
import math
import sys


def dist_km(a, b):
    return math.hypot((a[0] - b[0]) * 90627 * math.cos(math.radians(32)),
                      (a[1] - b[1]) * 110574) / 1000.0


for lid in sys.stdin.read().split():
    lid = lid.strip()
    if not lid or "/" in lid or "\\" in lid or ".." in lid:
        continue
    try:
        d = json.load(open("data/lines/%s.json" % lid, encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        continue
    kept = []
    for i, s in enumerate(d.get("stations", [])):
        p = (float(s["lon"]), float(s["lat"]))
        if all(dist_km(p, q) > 8.0 for q in kept):
            kept.append(p)
            print("%s s%d" % (lid, i))

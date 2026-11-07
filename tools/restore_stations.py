# -*- coding: utf-8 -*-
"""从构建备份还原被错误拖拽的车站坐标（偏差 >25km 视为拖站事故）。

用法（Python 零文件 I/O，落盘由 bash 重定向完成）：
  plan: python tools/restore_stations.py plan > restore_fixes.json
        输出 {文件名: {站id: [lon, lat]}}——当前坐标与备份坐标偏差
        >25km 的站点（备份 = 构建前原始数据，站坐标可信）。
  apply: stdin = 线路 JSON 与修正表 JSON 顺序拼接；
        输出修正后的线路 JSON。
"""
import json
import math
import sys

import glob

BAK_DIR = "tools/cache12306/lines_backup"
DEVIATION_M = 25000.0


def dist_m(a, b):
    return math.hypot((a[0] - b[0]) * 90558.0, (a[1] - b[1]) * 110574.0)


def plan():
    fixes = {}
    for cur_path in sorted(glob.glob("data/lines/*.json")):
        lid = cur_path.replace("\\", "/").split("/")[-1][:-5]
        bak_path = "%s/%s.json" % (BAK_DIR, lid)
        try:
            cur = json.load(open(cur_path, encoding="utf-8"))
            bak = json.load(open(bak_path, encoding="utf-8"))
        except Exception:
            continue
        bak_pos = {}
        for s in bak.get("stations", []):
            bak_pos[s["id"]] = (float(s["lon"]), float(s["lat"]))
        fix = {}
        for s in cur.get("stations", []):
            if s["id"] in bak_pos:
                bp = bak_pos[s["id"]]
                cp = (float(s["lon"]), float(s["lat"]))
                if dist_m(cp, bp) > DEVIATION_M:
                    fix[s["id"]] = [bp[0], bp[1]]
        if fix:
            fixes[lid] = fix
    json.dump(fixes, sys.stdout, ensure_ascii=False, indent=1)
    total = sum(len(v) for v in fixes.values())
    print("[plan] %d 条线 / %d 站需要还原" % (len(fixes), total), file=sys.stderr)


def apply():
    docs = []
    dec = json.JSONDecoder()
    text = sys.stdin.read()
    pos = 0
    while len(docs) < 2:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            break
        doc, pos = dec.raw_decode(text, pos)
        docs.append(doc)
    if len(docs) < 2:
        docs.append({})
    d, fixes = docs[0], docs[1]
    lid = str(d.get("id", ""))
    fixes = fixes.get(lid, {})
    n = 0
    for s in d.get("stations", []):
        if s["id"] in fixes:
            fx = fixes[s["id"]]
            s["lon"], s["lat"] = fx[0], fx[1]
            n += 1
    if n:
        print("[apply] 还原 %d 站" % n, file=sys.stderr)
    json.dump(d, sys.stdout, ensure_ascii=False, indent=2)


def main():
    args = sys.argv[1:]
    if args and args[0] == "plan":
        plan()
    elif args and args[0] == "apply":
        apply()
    else:
        print("用法: restore_stations.py plan > restore_fixes.json\n"
              "      restore_stations.py apply < (line.json + fixes.json)",
              file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

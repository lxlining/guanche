# -*- coding: utf-8 -*-
"""共享车站坐标归一：同名车站在不同线路文件里的坐标必须一致。

背景：OSM 线形替换时部分车站坐标被修正到真实位置，但同名车站在
其它未替换/未修正线路里仍是旧近似值——地图上出现重复站名标签
与双站点圆点。

用法（Python 零文件 I/O，落盘由 bash 重定向完成）：
  plan: python tools/normalize_stations.py plan > fixes.json
        输出 {站名: [lon, lat]}——同名站坐标离散 >300m 时，
        取「OSM 真实线形」线路里的坐标（多数一致时取众数）。
  apply: python tools/normalize_stations.py apply <file> < fixes.json
        输出该文件修正后的完整 JSON（无修正则原样输出）。
"""
import glob
import json
import sys

SPREAD_M = 300.0


def dist_m(a, b):
    import math
    return math.hypot((a[0] - b[0]) * 90558.0, (a[1] - b[1]) * 110574.0)


def collect():
    """站名 -> [(file, lon, lat, is_osm)]。"""
    by_name = {}
    for f in glob.glob("data/lines/*.json"):
        d = json.load(open(f, encoding="utf-8"))
        is_osm = "OSM 真实线形" in str(d.get("note", ""))
        for s in d.get("stations", []):
            by_name.setdefault(str(s["name"]), []).append(
                (f, float(s["lon"]), float(s["lat"]), is_osm))
    return by_name


def plan():
    by_name = collect()
    fixes = {}
    for name, entries in by_name.items():
        coords = [(e[1], e[2]) for e in entries]
        if len(coords) < 2:
            continue
        dmax = 0.0
        for i in range(len(coords)):
            for j in range(i + 1, len(coords)):
                dmax = max(dmax, dist_m(coords[i], coords[j]))
        if dmax <= SPREAD_M:
            continue
        # 聚类多数：0.05° 网格分簇取最大簇（异常修正值自然落单），
        # 簇内优先 OSM 修正值
        clusters = {}
        for e in entries:
            key = (round(e[1] / 0.05), round(e[2] / 0.05))
            clusters.setdefault(key, []).append(e)
        big = max(clusters.values(), key=len)
        osm = [(e[1], e[2]) for e in big if e[3]]
        pick = osm[0] if osm else (big[0][1], big[0][2])
        fixes[name] = [pick[0], pick[1]]
    json.dump(fixes, sys.stdout, ensure_ascii=False, indent=1)
    print("[plan] %d 站需要归一（共 %d 站名）" % (len(fixes), len(by_name)),
          file=sys.stderr)


def apply():
    """stdin = 线路 JSON 与修正表 JSON 顺序拼接（零文件访问）。"""
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
    n = 0
    for s in d.get("stations", []):
        nm = str(s["name"])
        if nm in fixes:
            fx = fixes[nm]
            if abs(float(s["lon"]) - fx[0]) > 1e-9 or abs(float(s["lat"]) - fx[1]) > 1e-9:
                s["lon"], s["lat"] = fx[0], fx[1]
                n += 1
    if n:
        print("[apply] 修正 %d 站" % n, file=sys.stderr)
    json.dump(d, sys.stdout, ensure_ascii=False, indent=2)


def main():
    args = sys.argv[1:]
    if args and args[0] == "plan":
        plan()
    elif args and args[0] == "apply":
        apply()
    else:
        print("用法: normalize_stations.py plan > fixes.json\n"
              "      normalize_stations.py apply <file.json> < fixes.json",
              file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

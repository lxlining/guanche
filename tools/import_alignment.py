# -*- coding: utf-8 -*-
"""把外部 GeoJSON 线形（如 OpenStreetMap 导出的京沪高铁走向）合并进线路文件。

用法（输入文件固定为 tools/cache12306/alignment.geojson）：
  1. 把 GeoJSON 保存为 tools/cache12306/alignment.geojson
  2. python tools/import_alignment.py > data/lines/jinghu_hsr.new.json
  3. 人工核对后，用输出中的 geometry 数组替换 data/lines/jinghu_hsr.json
     里的 geometry 字段（station 标记应逐站齐全且有序）。

GeoJSON 支持 FeatureCollection / Feature / 几何对象，含 LineString 或
MultiLineString（WGS84 经纬度）。流程：
1. 以 23 座车站包围盒（外扩 0.3°）筛选线段；
2. 按「共享端点」拼接全部折线（OSM 导出通常是数百条短 way）；
3. Douglas-Peucker 简化（约 150 m 容差）；
4. 把每座车站吸附到折线最近顶点（站序单调向前搜索），顶点坐标替换为站坐标；
5. 输出完整线路 JSON（站点信息不变，geometry 替换）。
"""
import json
import math
import os
import sys

import timetable_lib as lib

INPUT_FILE = os.path.join("tools", "cache12306", "alignment.geojson")
SIMPLIFY_TOL_M = 150.0
BBOX_PAD = 0.3
SNAP_WARN_M = 2000.0


def collect_linestrings(obj, out):
    if isinstance(obj, dict):
        if obj.get("type") == "FeatureCollection":
            for f in obj.get("features", []):
                collect_linestrings(f, out)
        elif obj.get("type") == "Feature":
            collect_linestrings(obj.get("geometry"), out)
        elif obj.get("type") == "LineString":
            out.append([(float(p[0]), float(p[1])) for p in obj["coordinates"]])
        elif obj.get("type") == "MultiLineString":
            for part in obj["coordinates"]:
                out.append([(float(p[0]), float(p[1])) for p in part])
    elif isinstance(obj, list) and obj and isinstance(obj[0], (list, tuple)) \
            and len(obj[0]) == 2:
        out.append([(float(p[0]), float(p[1])) for p in obj])


def pt_in_bbox(p, bbox):
    return bbox[0] <= p[0] <= bbox[1] and bbox[2] <= p[3] <= bbox[3]


def merge_chains(lines, bbox):
    """按共享端点拼接折线，返回主链（自最接近北京南的端点起走）。"""
    key = lambda p: (round(p[0], 5), round(p[1], 5))  # noqa: E731
    segs = [ln for ln in lines if all(pt_in_bbox(p, bbox) for p in ln)]
    end_map = {}
    for i, ln in enumerate(segs):
        for e in (0, -1):
            end_map.setdefault(key(ln[e]), []).append((i, e))
    used = [False] * len(segs)

    def walk(start_idx, start_end):
        chain = []
        i, e = start_idx, start_end
        while True:
            if used[i]:
                break
            used[i] = True
            ln = segs[i]
            seq = ln if e == 0 else ln[::-1]
            if chain:
                chain.extend(seq[1:] if seq else seq)
            else:
                chain.extend(seq)
            nxt_key = key(seq[-1])
            nxt = None
            for j, je in end_map.get(nxt_key, []):
                if j != i and not used[j]:
                    nxt = (j, je)
                    break
            if nxt is None:
                break
            i, e = nxt
        return chain

    bjn = (116.378, 39.865)
    best = None
    best_d = 1e18
    for i, ln in enumerate(segs):
        for e in (0, -1):
            p = ln[e]
            d = (p[0] - bjn[0]) ** 2 + (p[1] - bjn[1]) ** 2
            if d < best_d:
                best_d = d
                best = (i, e)
    if best is None:
        raise SystemExit("包围盒内没有可用线段")
    return walk(best[0], best[1]), len(segs)


def dist_m(a, b):
    return math.hypot((a[0] - b[0]) * lib.M_PER_DEG_LON, (a[1] - b[1]) * lib.M_PER_DEG_LAT)


def dp_simplify(pts, tol):
    """Douglas-Peucker（米制空间）。"""
    if len(pts) < 3:
        return list(pts)

    def perp(p, a, b):
        ax, ay = (a[0] - p[0]) * lib.M_PER_DEG_LON, (a[1] - p[1]) * lib.M_PER_DEG_LAT
        bx, by = (b[0] - p[0]) * lib.M_PER_DEG_LON, (b[1] - p[1]) * lib.M_PER_DEG_LAT
        abx, aby = bx - ax, by - ay
        l2 = abx * abx + aby * aby
        if l2 <= 0:
            return math.hypot(ax, ay)
        t = max(0.0, min(1.0, (ax * abx + ay * aby) / l2))
        dx, dy = ax - abx * t, ay - aby * t
        return math.hypot(dx, dy)

    stack = [(0, len(pts) - 1)]
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    while stack:
        i0, i1 = stack.pop()
        if i1 <= i0 + 1:
            continue
        dmax, imax = -1.0, -1
        for k in range(i0 + 1, i1):
            d = perp(pts[k], pts[i0], pts[i1])
            if d > dmax:
                dmax, imax = d, k
        if dmax > tol:
            keep[imax] = True
            stack.append((i0, imax))
            stack.append((imax, i1))
    return [p for p, k in zip(pts, keep) if k]


def snap_stations(pts, stations):
    """站序单调向前吸附；返回 (geometry 数组, 告警列表)。"""
    out = [[p[0], p[1], None] for p in pts]
    warns = []
    prev_idx = 0
    for s in stations:
        sid, lon, lat = s["id"], float(s["lon"]), float(s["lat"])
        best_i, best_d = prev_idx, 1e18
        for i in range(prev_idx, len(pts)):
            d = dist_m((lon, lat), pts[i])
            if d < best_d:
                best_d, best_i = d, i
        if best_d > SNAP_WARN_M:
            warns.append("%s 距线形最近点 %.0f m（超阈值，检查数据）" % (sid, best_d))
        out[best_i] = [lon, lat, sid]
        prev_idx = best_i
    return out, warns


def main():
    if not os.path.isfile(INPUT_FILE):
        raise SystemExit("找不到输入文件 %s —— 请先把 GeoJSON 保存到该位置" % INPUT_FILE)
    with open(INPUT_FILE, encoding="utf-8") as f:
        geo = json.load(f)

    line, stations, station_arc, total_len = lib.load_line()
    lons = [float(s["lon"]) for s in line["stations"]]
    lats = [float(s["lat"]) for s in line["stations"]]
    bbox = (min(lons) - BBOX_PAD, max(lons) + BBOX_PAD,
            min(lats) - BBOX_PAD, max(lats) + BBOX_PAD)

    raw = []
    collect_linestrings(geo, raw)
    if not raw:
        raise SystemExit("GeoJSON 中未找到 LineString")
    chain, n_seg = merge_chains(raw, bbox)
    if len(chain) < 10:
        raise SystemExit("可用线段过少（%d 点），检查包围盒或数据" % len(chain))

    simplified = dp_simplify(chain, SIMPLIFY_TOL_M)
    geometry, warns = snap_stations(simplified, line["stations"])

    length_m = 0.0
    for a, b in zip(simplified, simplified[1:]):
        length_m += dist_m(a, b)
    km = length_m / 1000.0
    if abs(km - 1302.0) / 1302.0 > 0.10:
        warns.append("线形总长 %.0f km 与京沪高铁 1302 km 偏差超 10%%" % km)

    out = dict(line)
    out["geometry"] = geometry
    out["note"] = (line.get("note", "") + " | geometry 已由 alignment.geojson "
                   "导入的真实线形替换。").strip(" |")
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    print()
    print("[统计] 输入折线 %d 条（包围盒内 %d 条）-> 链 %d 点 -> 简化 %d 点，"
          "线长 %.0f km" % (len(raw), n_seg, len(chain), len(simplified), km),
          file=sys.stderr)
    for w in warns[:30]:
        print("  [警告]", w, file=sys.stderr)


if __name__ == "__main__":
    main()

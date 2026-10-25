# -*- coding: utf-8 -*-
"""时刻表工具共享库：几何弧长、运行时分计算、占用采样（供整理脚本与生成器共用）。

约定：所有脚本必须在项目根目录运行（以 project.godot 所在目录为根），
只允许读写 data/ 下的相对路径，禁止任何上级目录引用。
"""
import json
import math
import os


def data_path(*parts) -> str:
    """构造 data/ 下的相对路径，并做显式安全校验。"""
    if not os.path.isfile(os.path.join("project.godot")):
        raise SystemExit("请在项目根目录运行本脚本（未找到 project.godot）")
    for part in parts:
        if not part or "/" in part or "\\" in part or part in (".", ".."):
            raise SystemExit("非法路径片段：%r" % part)
    return os.path.join("data", *parts)


LAT0 = 35.5
LON0 = 118.85
M_PER_DEG_LAT = 110574.0
M_PER_DEG_LON = 111320.0 * math.cos(math.radians(LAT0))

# 服务等级：平均技术速度 (km/h)
SPEEDS = {"express": 315.0, "normal": 288.0, "slow": 262.0, "sleeper": 205.0}
DWELL_DEFAULT = {"express": 4, "normal": 2, "slow": 2, "sleeper": 5}
HEADWAY_M = 2000.0    # 同方向“贴近”距离（米）
MAX_PROX_S = 720.0    # 持续贴近超过 12 分钟才视为冲突（短暂越行放行）


def arc_at(stops, station_arc, t):
    """既有车在时刻 t 的弧长位置；不在运行时段返回 None（含停站取站位）。"""
    if t < stops[0][2] or t > stops[-1][1]:
        return None
    for i in range(len(stops)):
        if stops[i][1] <= t <= stops[i][2]:  # 停站/待发中
            return station_arc[stops[i][0]]
    for i in range(len(stops) - 1):
        if stops[i][2] <= t <= stops[i + 1][1]:
            a0 = station_arc[stops[i][0]]
            a1 = station_arc[stops[i + 1][0]]
            t0 = stops[i][2]
            t1 = stops[i + 1][1]
            f = (t - t0) / max(t1 - t0, 1.0)
            return a0 + (a1 - a0) * f
    return None


def has_conflict(direction, cand_stops, station_arc, existing):
    """existing: [(code, dir, stops)]。
    规则：同方向列车与候选车持续贴近（<2km）超过 12 分钟视为冲突——
    排除同速尾随、同站堆叠、全程并行；允许短时间的站内越行式交叉。"""
    cand_samples = sample_runs(cand_stops, station_arc, step=30.0)
    if not cand_samples:
        return False
    t_lo = cand_samples[0][0]
    t_hi = cand_samples[-1][0]
    for code2, dir2, stops2 in existing:
        if dir2 != direction:
            continue
        if stops2[-1][1] < t_lo or stops2[0][2] > t_hi:
            continue
        run = 0.0
        for t, arc in cand_samples:
            a2 = arc_at(stops2, station_arc, t)
            if a2 is not None and abs(a2 - arc) < HEADWAY_M:
                run += 30.0
                if run > MAX_PROX_S:
                    return True
            else:
                run = 0.0
    return False


def load_line():
    return load_line_doc("jinghu_hsr")


def load_line_doc(line_id):
    with open(data_path("lines", line_id + ".json"), encoding="utf-8") as f:
        line = json.load(f)
    pts = []
    for g in line["geometry"]:
        lon, lat = float(g[0]), float(g[1])
        pts.append(((lon - LON0) * M_PER_DEG_LON, -(lat - LAT0) * M_PER_DEG_LAT))
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + math.dist(pts[i - 1], pts[i]))
    station_arc = {}
    for g, c in zip(line["geometry"], cum):
        if len(g) > 2 and g[2]:
            station_arc[g[2]] = c
    stations = {s["id"]: s for s in line["stations"]}
    return line, stations, station_arc, cum[-1]


def parse_hhmm(s):
    h, m = s.split(":")
    return int(h) * 3600 + int(m) * 60


def fmt_hhmm(sec):
    day = int(sec // 86400)
    sec = int(sec % 86400)
    base = "%02d:%02d" % (sec // 3600, sec % 3600 // 60)
    return base + ("+1" if day else "")


def hhmm_or_none(v):
    return None if v in (None, "") else fmt_hhmm(v)


def normalize_stops(raw_stops):
    """JSON 停站（"HH:MM"，可跨日）-> 绝对秒 [(sid, arr, dep)]，处理跨午夜。"""
    out = []
    offset = 0.0
    prev = -1.0
    for s in raw_stops:
        arr = parse_hhmm(s["arr"]) + offset if s.get("arr") else None
        if arr is not None:
            if arr < prev:
                offset += 86400.0
                arr += 86400.0
            prev = arr
        dep = parse_hhmm(s["dep"]) + offset if s.get("dep") else None
        if dep is not None:
            if dep < prev:
                offset += 86400.0
                dep += 86400.0
            prev = dep
        if arr is None:
            arr = dep
        if dep is None:
            dep = arr
        out.append((s["sid"], arr, dep))
    return out


def build_schedule(dep, stop_sids, station_arc, service, dwell=None, pace=1.0):
    """按区段长度/服务速度推算各站到发时刻（整数分钟，最大余数法分配 pace 缩放）。
    返回 [(sid, arr, dep)] 绝对秒。dep 为绝对秒。"""
    v = SPEEDS[service] * 1000.0 / 60.0  # 米/分钟
    dflt = DWELL_DEFAULT[service]
    dwell = dwell or {}
    raw = []
    for i in range(len(stop_sids) - 1):
        a0 = station_arc[stop_sids[i]]
        a1 = station_arc[stop_sids[i + 1]]
        L = abs(a1 - a0)
        raw.append(max(5.0, L / v + 1.5))
    total = sum(raw)
    target = total * pace
    scaled = [r / total * target for r in raw]
    rounded = [int(math.floor(s)) for s in scaled]
    rem = int(round(target)) - sum(rounded)
    order = sorted(range(len(scaled)), key=lambda k: scaled[k] - math.floor(scaled[k]), reverse=True)
    for k in range(max(0, rem)):
        rounded[order[k % len(order)]] += 1

    stops = [(stop_sids[0], dep, dep)]
    t = dep
    n = len(stop_sids)
    for i in range(1, n):
        t += rounded[i - 1] * 60  # 区段运行时分（分钟）换算为秒
        arr = t
        dw = 0 if i == n - 1 else int(dwell.get(stop_sids[i], dflt))
        dep_t = arr + dw * 60
        stops.append((stop_sids[i], arr, dep_t))
        t = dep_t
    return stops


def validate_schedule(stops, station_arc, code, warnings):
    """相邻停站间平均速度校验。"""
    for i in range(1, len(stops)):
        sid0, _, dep0 = stops[i - 1]
        sid1, arr1, _ = stops[i]
        L = abs(station_arc[sid1] - station_arc[sid0])
        dur = arr1 - dep0
        if dur <= 0:
            warnings.append("%s 时刻非单调 @%s" % (code, sid1))
            continue
        v = L / dur * 3.6
        if v > 360.0:
            warnings.append("%s 区段 %s→%s 均速 %.0f km/h 超限" % (code, sid0, sid1, v))


def sample_runs(stops, station_arc, step=20.0):
    """采样运行段（不含停站）：[(t, arc)]。"""
    out = []
    for i in range(1, len(stops)):
        a0 = station_arc[stops[i - 1][0]]
        a1 = station_arc[stops[i][0]]
        t0 = stops[i - 1][2]
        t1 = stops[i][1]
        dur = t1 - t0
        if dur <= 0:
            continue
        n = max(2, int(dur / step))
        for k in range(n + 1):
            f = k / n
            out.append((t0 + f * dur, a0 + (a1 - a0) * f))
    return out


def dwell_windows(stops):
    """停站（含始发待发）时间窗，用于交会豁免。"""
    wins = [(stops[0][2] - 900, stops[0][2] + 60)]
    for i in range(1, len(stops)):
        wins.append((stops[i][1] - 60, stops[i][2] + 60))
    return wins


def make_occupancy(trains, station_arc):
    """（保留备用）trains: [(code, dir, stops)] -> occ[dir][minute] = [(arc, code)]"""
    occ = {"down": {}, "up": {}}
    dwell = {}
    for code, direction, stops in trains:
        for t, arc in sample_runs(stops, station_arc, step=30.0):
            m = int(t // 60)
            for mm in (m, m + 1):
                occ[direction].setdefault(mm, []).append((arc, code))
        dwell[code] = dwell_windows(stops)
    return occ, dwell


def load_all_lines():
    """加载 data/lines/ 下全部线路 -> {line_id: (doc, stations, station_arc, total_len)}"""
    out = {}
    lines_dir = os.path.join("data", "lines")
    for fn in sorted(os.listdir(lines_dir)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(lines_dir, fn), encoding="utf-8") as f:
            doc = json.load(f)
        pts = []
        for g in doc["geometry"]:
            lon, lat = float(g[0]), float(g[1])
            pts.append(((lon - LON0) * M_PER_DEG_LON, -(lat - LAT0) * M_PER_DEG_LAT))
        cum = [0.0]
        for i in range(1, len(pts)):
            cum.append(cum[-1] + math.dist(pts[i - 1], pts[i]))
        station_arc = {}
        for g, c in zip(doc["geometry"], cum):
            if len(g) > 2 and g[2]:
                station_arc[g[2]] = c
        stations = {s["id"]: s for s in doc["stations"]}
        out[doc["id"]] = (doc, stations, station_arc, cum[-1])
    return out

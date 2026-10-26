# -*- coding: utf-8 -*-
"""把 12306 抓取缓存按线路归属转换为多线时刻表 -> 标准输出 JSON。

用法：python tools/build_from_12306.py > data/timetables/all.json

归属规则：对每个车次，在全部已加载线路上计算「本线停站数」（并列取本线
覆盖里程大者），取最优线路；停站 < 2 站的车次不入库。始发/终到与全部
到发时刻均为 12306 真实数据；车型为按交路特征推测的图鉴标注。
"""
import hashlib
import json
import os
import sys

import timetable_lib as lib


def load_jsonl(path):
    out = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    out[rec["key"]] = rec["value"]
                except json.JSONDecodeError:
                    continue
    return out


def parse_time_abs(stops):
    """把 12306 停站序列转成绝对分钟，处理跨午夜。"""
    out = []
    day = 0
    prev_mod = None
    for st in stops:
        name = st.get("station_name", "")
        vals = {}
        for field in ("arrive_time", "start_time"):
            raw = st.get(field)
            if raw in (None, "", "--", "----"):
                vals[field] = None
                continue
            try:
                hh, mm = raw.split(":")
                m = int(hh) * 60 + int(mm)
            except ValueError:
                return None
            if prev_mod is not None and m < prev_mod - 720:
                day += 1
            prev_mod = m
            vals[field] = m + day * 1440
        out.append((name, vals["arrive_time"], vals["start_time"]))
    return out


def fmt_abs(minutes):
    if minutes is None:
        return None
    return "%02d:%02d" % (minutes // 60, minutes % 60)


def guess_type(code, matched_count, crosses_midnight):
    """车型推测（12306 不公开车底信息）。哈希仅用于确定性分派，非安全用途。"""
    if code.startswith("D"):
        return "CRH2E" if crosses_midnight else "CRH380B"
    if matched_count <= 4:
        n = 0
        for ch in code:
            n = n * 10 + (ord(ch) % 10)
        return "CR400AF-BZ" if n % 2 == 0 else "CR400BF-BZ"
    pool = [
        ("CR400AF", 24), ("CR400BF", 20), ("CR400AF-A", 9), ("CR400BF-A", 9),
        ("CRH380B", 13), ("CRH380A", 9), ("CRH380BL", 5), ("CRH380AL", 4),
        ("CRH380CL", 4), ("CRH2C", 3),
    ]
    h = int(hashlib.sha256(code.encode()).hexdigest(), 16) % 100
    acc = 0
    for tid, w in pool:
        acc += w
        if h < acc:
            return tid
    return "CR400AF"


def main():
    all_lines = lib.load_all_lines()
    lines = {}
    for line_id, (doc, stations, station_arc, total) in all_lines.items():
        lines[line_id] = {
            "names": {s["name"]: s["id"] for s in doc["stations"]},
            "order": {s["id"]: i for i, s in enumerate(doc["stations"])},
            "station_arc": station_arc,
            "short": doc.get("short", line_id),
        }

    # 全网站名图：节点=站名，边=同线相邻站对（跨线共站自然连通）
    name_graph = {}
    for line_id, L in lines.items():
        doc = all_lines[line_id][0]
        seq = [s["name"] for s in doc["stations"]]
        for a, b in zip(seq, seq[1:]):
            if a == b:
                continue
            name_graph.setdefault(a, set()).add(b)
            name_graph.setdefault(b, set()).add(a)

    def shortest_path(a, b, max_hops=16):
        if a == b:
            return [a]
        if a not in name_graph or b not in name_graph:
            return None
        prev = {a: None}
        queue = [a]
        hops = 0
        while queue and hops < max_hops:
            nxt = []
            for node in queue:
                for nb in name_graph.get(node, ()):
                    if nb in prev:
                        continue
                    prev[nb] = node
                    if nb == b:
                        path = [b]
                        while prev[path[-1]] is not None:
                            path.append(prev[path[-1]])
                        path.reverse()
                        return path
                    nxt.append(nb)
            queue = nxt
            hops += 1
        return None

    with open(os.path.join("tools", "cache12306", "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    details = load_jsonl(os.path.join("tools", "cache12306", "detail.jsonl"))

    warnings = []
    trains_out = []
    used_codes = set()
    stats = {"no_detail": 0, "err": 0, "no_line": 0, "dup": 0}

    for t in index:
        det = details.get(t["train_no"])
        if det is None:
            stats["no_detail"] += 1
            continue
        if "error" in det:
            stats["err"] += 1
            continue
        abs_stops = parse_time_abs(det.get("stops", []))
        if not abs_stops:
            stats["err"] += 1
            continue

        code = t.get("code", "")
        if code == "" or code in used_codes:
            stats["dup" if code in used_codes else "err"] += 1
            continue

        # 逐站归属：每个站名可能存在于多条线路（如南京南属京沪/宁杭/沿江）。
        # 两遍贪心：第一遍按「上一站线路优先」选；第二遍对多线站做前向连续性
        # 校正（优先选与下一站候选相交的线路），保证首腿从停站 0 开始。
        # 腿（leg）= 同一线路上连续的停站区间；切换点即真实联络线接入站。
        def cands_of(idx):
            name = abs_stops[idx][0]
            return [lid for lid, L in lines.items() if name in L["names"]]

        cand_list = [cands_of(i) for i in range(len(abs_stops))]
        N = len(abs_stops)
        stop_line = [None] * N
        for i in range(N):
            cands = cand_list[i]
            if not cands:
                continue
            choice = cands[0]
            if i > 0 and stop_line[i - 1] in cands:
                choice = stop_line[i - 1]  # 延续上一腿
            elif i + 1 < N:
                nxt = set(cand_list[i + 1])
                shared = [c for c in cands if c in nxt]
                if shared:
                    choice = shared[0]  # 前向连续性
            stop_line[i] = choice

        legs = []  # {line_id, i0, i1}（闭区间，停站下标）
        i = 0
        while i < N:
            if stop_line[i] is None:
                i += 1
                continue
            j = i
            while j + 1 < N and stop_line[j + 1] == stop_line[i]                     and abs_stops[j + 1][0] in lines[stop_line[i]]["names"]:
                j += 1
            if j > i:
                legs.append({"line_id": stop_line[i], "i0": i, "i1": j})
            i = j + 1

        # 至少一条腿（≥2 连续同线停站）；允许真实首末站在网外——
        # 列车从首个网内停靠站渲染到末个网内停靠站，网外部分标记 off_map。
        if not legs:
            stats["no_line"] += 1
            continue
        used_codes.add(code)

        # 主线 = 里程覆盖最大的腿（列表统计/筛选用）
        def leg_cover(leg):
            L = lines[leg["line_id"]]
            sids = L["names"]
            return abs(L["station_arc"][sids[abs_stops[leg["i1"]][0]]]
                       - L["station_arc"][sids[abs_stops[leg["i0"]][0]]])
        primary = max(legs, key=leg_cover)["line_id"]

        from_name = abs_stops[0][0]
        to_name = abs_stops[-1][0]
        crosses = any(m >= 1440 for _, a, dd in abs_stops for m in (a or 0, dd or 0))

        # 全程停站（按运行顺序，含所属线路）
        stops_json = []
        for i, (name, a, dd) in enumerate(abs_stops):
            stops_json.append({
                "sid": lines[stop_line[i]]["names"][name] if stop_line[i] else name,
                "line": stop_line[i],
                "arr": fmt_abs(a) if i > 0 else None,
                "dep": fmt_abs(dd) if i < N - 1 else None,
            })

        # 物理校验：逐腿校验区段均速
        for leg in legs:
            L = lines[leg["line_id"]]
            norm = []
            off = 0.0
            prev = -1.0
            for i in range(leg["i0"], leg["i1"] + 1):
                _, a, dd = abs_stops[i]
                av = a if a is not None else dd
                dv = dd if dd is not None else a
                for v in (av, dv):
                    if v is None:
                        continue
                    w = v + off
                    if w < prev:
                        off += 1440.0  # 跨日（分钟）
                        w += 1440.0
                    prev = w
                norm.append((L["names"][abs_stops[i][0]], (av + off) * 60 if av is not None else None,
                             (dv + off) * 60 if dv is not None else None))
            lib.validate_schedule(norm, all_lines[leg["line_id"]][2], code, warnings)

        legs_json = []
        for k in range(len(legs)):
            leg = legs[k]
            entry = {"line": leg["line_id"], "i0": leg["i0"], "i1": leg["i1"]}
            if k + 1 < len(legs):
                gap_a = abs_stops[leg["i1"]][0]
                gap_b = abs_stops[legs[k + 1]["i0"]][0]
                path = shortest_path(gap_a, gap_b)
                if path and len(path) >= 2:
                    entry["transfer_path"] = path
            legs_json.append(entry)
        n0 = legs[0]["i1"] - legs[0]["i0"] + 1
        trains_out.append({
            "code": code,
            "line": primary,
            "legs": legs_json,
            "type": guess_type(code, n0, crosses),
            "from": from_name,
            "to": to_name,
            "off_map": stop_line[0] is None or stop_line[-1] is None                 or legs[0]["i0"] != 0 or legs[-1]["i1"] != N - 1,
            "express": n0 <= 4,  # 首腿沿线停站 ≤4 站视为「大站车」
            "generated": False,
            "source": "12306",
            "date": "2026-10-29",
            "stops": stops_json,
        })

    out = {"note": "12306 公开查询接口抓取的真实时刻表（查询日 2026-10-29），"
                   "列车按真实路径分段跨线运行（legs）；车型为推测标注。"
                   "重新生成：tools/build_from_12306.py",
           "trains": trains_out}
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    print()
    per_line_stats = {}
    for tr in trains_out:
        pl = tr["line"]
        per_line_stats[pl] = per_line_stats.get(pl, 0) + 1
    print("[统计] 总入库 %d 趟 | 无详情 %d | 错误 %d | 无法成腿 %d | 重号 %d"
          % (len(trains_out), stats["no_detail"], stats["err"],
             stats["no_line"], stats["dup"]), file=sys.stderr)
    for line_id in sorted(per_line_stats, key=lambda k: -per_line_stats[k]):
        print("  主线 %-18s %5d 趟" % (line_id, per_line_stats[line_id]), file=sys.stderr)
    cross = sum(1 for tr in trains_out if len(tr["legs"]) > 1)
    print("[统计] 跨线列车（多腿）%d 趟" % cross, file=sys.stderr)
    for w in warnings[:40]:
        print("  [警告]", w, file=sys.stderr)


if __name__ == "__main__":
    main()

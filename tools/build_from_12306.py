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

    with open(os.path.join("tools", "cache12306", "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    details = load_jsonl(os.path.join("tools", "cache12306", "detail.jsonl"))

    warnings = []
    per_line = {line_id: [] for line_id in lines}
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

        # 归属：本线停站数最多，并列取覆盖里程大者
        best = None
        for line_id, L in lines.items():
            matched = [(name, a, d) for name, a, d in abs_stops if name in L["names"]]
            if len(matched) < 2:
                continue
            idxs = [L["order"][L["names"][name]] for name, _, _ in matched]
            if all(x < y for x, y in zip(idxs, idxs[1:])):
                direction = "down"
            elif all(x > y for x, y in zip(idxs, idxs[1:])):
                direction = "up"
            else:
                continue
            covered = abs(L["station_arc"][L["names"][matched[-1][0]]]
                          - L["station_arc"][L["names"][matched[0][0]]])
            cand = (len(matched), covered, line_id, direction, matched)
            if best is None or (cand[0], cand[1]) > (best[0], best[1]):
                best = cand
        if best is None:
            stats["no_line"] += 1
            continue
        n, _, line_id, direction, matched = best
        used_codes.add(code)

        L = lines[line_id]
        from_name = abs_stops[0][0]
        to_name = abs_stops[-1][0]
        stops_json = []
        for i, (name, a, d) in enumerate(matched):
            stops_json.append({
                "sid": L["names"][name],
                "arr": fmt_abs(a) if i > 0 else None,
                "dep": fmt_abs(d) if i < n - 1 else None,
            })

        # 转绝对秒做物理校验（处理 >24h 的跨日时刻）
        norm = []
        off = 0.0
        prev = -1.0
        for s in stops_json:
            a = lib.parse_hhmm(s["arr"]) if s["arr"] else None
            d = lib.parse_hhmm(s["dep"]) if s["dep"] else None
            av = a if a is not None else d
            dv = d if d is not None else a
            if av is not None:
                v = av + off
                if v < prev:
                    off += 86400.0
                    v += 86400.0
                prev = v
                av = v
            if dv is not None:
                v = dv + off
                if v < prev:
                    off += 86400.0
                    v += 86400.0
                prev = v
                dv = v
            norm.append((s["sid"], av, dv))
        lib.validate_schedule(norm, all_lines[line_id][2], code, warnings)

        crosses = any(m >= 1440 for _, a, d in matched for m in (a or 0, d or 0))
        per_line[line_id].append({
            "code": code,
            "line": line_id,
            "dir": direction,
            "type": guess_type(code, n, crosses),
            "from": from_name,
            "to": to_name,
            "off_map": from_name not in L["names"] or to_name not in L["names"],
            "express": n <= 4,  # 沿线停站 ≤4 站视为「大站车」
            "generated": False,
            "source": "12306",
            "date": "2026-10-29",
            "stops": stops_json,
        })

    out = {"note": "12306 公开查询接口抓取的真实时刻表（查询日 2026-10-29），"
                   "按线路归属分组；车型为推测标注。重新生成：tools/build_from_12306.py",
           "lines": {}}
    for line_id in sorted(per_line):
        out["lines"][line_id] = {
            "note": "线路 %s 的真实车次" % line_id,
            "trains": per_line[line_id],
        }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    print()
    print("[统计] 总入库 %d 趟 | 无详情 %d | 错误 %d | 不属任何线路 %d | 重号 %d"
          % (sum(len(v) for v in per_line.values()), stats["no_detail"], stats["err"],
             stats["no_line"], stats["dup"]), file=sys.stderr)
    for line_id in sorted(per_line):
        print("  %s: %d 趟" % (line_id, len(per_line[line_id])), file=sys.stderr)
    for w in warnings[:40]:
        print("  [警告]", w, file=sys.stderr)


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""把 12306 抓取缓存转换为游戏时刻表 -> 标准输出 JSON。

  python tools/build_from_12306.py > data/timetables/real.json

筛选规则：车次详情中至少经停本项目 23 站中的 2 站，且停站沿线顺序单调
（下行=站序递增，上行=递减）。始发/终到与全部到发时刻均为 12306 真实数据；
12306 不公开车底（车型）信息，车型按交路特征推测标注，仅作图鉴参考。
"""
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
    """把 12306 停站序列转成绝对分钟，处理跨午夜。返回 [(station_name, arr_abs, dep_abs)]，
    始发 arr 为 None、终到 dep 为 None；无效行返回 None。"""
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
    """车型推测（12306 不公开车底信息）：大站直达 -> 智能复兴号；
    D 字头夜间 -> 动卧 CRH2E；其余按车次号稳定散重加权分派。"""
    if code.startswith("D"):
        return "CRH2E" if crosses_midnight else "CRH380B"
    if matched_count <= 4:  # 与 express 同口径：沿线停站 ≤4 站按旗舰车底推测
        n = 0
        for ch in code:
            n = n * 10 + (ord(ch) % 10)
        return "CR400AF-BZ" if n % 2 == 0 else "CR400BF-BZ"
    pool = [
        ("CR400AF", 28), ("CR400BF", 24), ("CR400AF-A", 10), ("CR400BF-A", 10),
        ("CRH380B", 12), ("CRH380A", 8), ("CRH380BL", 4), ("CRH380AL", 2), ("CRH380CL", 2),
    ]
    h = sum(ord(c) for c in code) % 100
    acc = 0
    for tid, w in pool:
        acc += w
        if h < acc:
            return tid
    return "CR400AF"


def main():
    line, stations, station_arc, total_len = lib.load_line()
    name2sid = {s["name"]: s["id"] for s in line["stations"]}
    order = {s["id"]: i for i, s in enumerate(line["stations"])}

    with open(os.path.join("tools", "cache12306", "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    details = load_jsonl(os.path.join("tools", "cache12306", "detail.jsonl"))

    warnings = []
    out = []
    used_codes = set()
    stats = {"no_detail": 0, "err": 0, "few_stops": 0, "nonmono": 0, "dup": 0}

    for t in index:
        train_no = t["train_no"]
        det = details.get(train_no)
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
        matched = [(name, a, d) for name, a, d in abs_stops if name in name2sid]
        if len(matched) < 2:
            stats["few_stops"] += 1
            continue
        idxs = [order[name2sid[name]] for name, _, _ in matched]
        if all(x < y for x, y in zip(idxs, idxs[1:])):
            direction = "down"
        elif all(x > y for x, y in zip(idxs, idxs[1:])):
            direction = "up"
        else:
            stats["nonmono"] += 1
            warnings.append("%s 停站顺序非单调，跳过" % t.get("code", train_no))
            continue

        code = t.get("code", "")
        if not code:
            continue
        if code in used_codes:
            stats["dup"] += 1
            continue
        used_codes.add(code)

        first_sid = name2sid[matched[0][0]]
        last_sid = name2sid[matched[-1][0]]
        from_name = abs_stops[0][0]   # 真实始发
        to_name = abs_stops[-1][0]    # 真实终到
        n = len(matched)
        stops_json = []
        for i, (name, a, d) in enumerate(matched):
            stops_json.append({
                "sid": name2sid[name],
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
        lib.validate_schedule(norm, station_arc, code, warnings)

        crosses = any(m >= 1440 for _, a, d in matched for m in (a or 0, d or 0))
        out.append({
            "code": code,
            "dir": direction,
            "type": guess_type(code, n, crosses),
            "from": from_name,
            "to": to_name,
            "off_map": from_name not in name2sid or to_name not in name2sid,
            "express": n <= 4,  # 沿线停站 ≤4 站视为「大站车」（真实 G1 停 7 站不算）
            "generated": False,
            "source": "12306",
            "date": "2026-10-29",
            "stops": stops_json,
        })

    out.sort(key=lambda x: (x["code"][0], x["code"]))
    doc = {
        "note": "12306 公开查询接口抓取的真实车次与到发时刻（查询日期 2026-10-29，"
                "经停本项目沿线 23 站的车次；始发/终到可能在图外）。"
                "12306 不公开车底信息，车型为按交路特征推测的图鉴标注。"
                "重新抓取：python tools/fetch_12306.py search/index/detail 后运行 build_from_12306.py。",
        "trains": out,
    }
    json.dump(doc, sys.stdout, ensure_ascii=False, indent=2)
    print()
    print("[统计] 入库 %d 趟 | 无详情 %d | 错误 %d | 停站不足 %d | 非单调 %d | 重号 %d"
          % (len(out), stats["no_detail"], stats["err"], stats["few_stops"],
             stats["nonmono"], stats["dup"]), file=sys.stderr)
    for w in warnings[:40]:
        print("  [警告]", w, file=sys.stderr)
    # 交会/天窗统计
    night = [t["code"] for t in out if any(
        s["arr"] and int(s["arr"].split(":")[0]) >= 24 or s["dep"] and int(s["dep"].split(":")[0]) >= 24
        for s in t["stops"])]
    late = [t["code"] for t in out if t["stops"][0]["dep"] and 22 <= int(t["stops"][0]["dep"].split(":")[0]) < 24]
    print("[统计] 跨午夜列车 %d 趟 %s | 22:00 后发车 %d 趟" % (len(night), night[:8], len(late)),
          file=sys.stderr)


if __name__ == "__main__":
    main()

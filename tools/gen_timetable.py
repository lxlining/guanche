# -*- coding: utf-8 -*-
"""在真实车次基础上生成补充车流（跨线车/临客/夜间动卧）-> 标准输出 JSON。

规则：
- 只与既有车流做同方向追踪间隔检查（弧长 12 km，双方均非停站时才算冲突；
  一方停站视为在站内越行/会让，予以豁免）。
- 高铁列车不进入 0:00-6:00 天窗；夜间动卧（D9xx）除外，作为生成补充内容。
- 车次号使用 G4xxx 临客段与 D9xx 动卧段，与真实车次区分。

用法：在项目根目录运行
  python tools/gen_timetable.py > data/timetables/generated.json
"""
import json
import random
import sys

import timetable_lib as lib

random.seed(20261024)

START_OK = 6 * 3600 + 10 * 60   # 06:10 之后发车
END_OK = 23 * 3600 + 55 * 60    # 23:55 之前终到

# 车型池：(type, weight)
POOL = [
    ("CRH380B", 26), ("CRH380A", 18), ("CRH380BL", 10), ("CRH380AL", 8),
    ("CR400AF", 10), ("CR400BF", 10), ("CR400AF-A", 6), ("CR400BF-A", 6),
    ("CR400AF-BZ", 4), ("CR400BF-BZ", 6), ("CRH380CL", 3), ("CRH2C", 3),
]
_POOL_TOTAL = sum(w for _, w in POOL)


def pick_type():
    r = random.uniform(0, _POOL_TOTAL)
    for tid, w in POOL:
        r -= w
        if r <= 0:
            return tid
    return "CRH380B"


# 模板：dir, first/last 为运行方向首末站；mids 为中间停站；
# from/to 为显示始发终到（跨线时指向图外）；off_map 标记跨线；
# dep 起止与步长（分钟）；max_n 目标数量。
TEMPLATES = [
    # ---------- 下行 ----------
    dict(dir="down", first="bjn", last="njn", to="杭州东", off_map=True,
         mids=[], service="express", dep=(420, 1180, 55), max_n=7),
    dict(dir="down", first="bjn", last="bbn", to="合肥南", off_map=True,
         mids=["jnx"], service="express", dep=(450, 1120, 90), max_n=4),
    dict(dir="down", first="bjn", last="jnx", to="青岛", off_map=True,
         mids=["lf", "tjn", "czx", "dzn"], service="normal", dep=(430, 1080, 80), max_n=4),
    dict(dir="down", first="bjn", last="xzd", to="兰州西", off_map=True,
         mids=["tjn", "jnx"], service="express", dep=(460, 1060, 110), max_n=3),
    dict(dir="down", first="bjn", last="njn",
         mids=["tjn", "jnx", "xzd", "bbn"], service="normal", dep=(540, 1150, 70), max_n=5),
    dict(dir="down", first="bjn", last="xzd",
         mids=["tjn", "czx", "jnx"], service="normal", dep=(600, 1100, 80), max_n=3),
    dict(dir="down", first="bjn", last="shhq",
         mids=["njn"], service="express", dep=(400, 1140, 55), max_n=6),
    dict(dir="down", first="bjn", last="shhq",
         mids=["tjn", "jnx", "xzd", "njn", "czb"], service="normal", dep=(410, 1090, 70), max_n=5),
    dict(dir="down", first="jnx", frm="青岛", off_map=True, last="shhq",
         mids=["ta", "xzd", "bbn", "njn", "czb", "szb"], service="normal", dep=(540, 1080, 75), max_n=4),
    # ---------- 上行 ----------
    dict(dir="up", first="shhq", last="bjn",
         mids=["njn"], service="express", dep=(400, 1140, 55), max_n=6),
    dict(dir="up", first="shhq", last="njn", to="安庆", off_map=True,
         mids=["ksn", "szb", "wxd", "czb", "zjn"], service="normal", dep=(480, 1140, 80), max_n=4),
    dict(dir="up", first="shhq", last="xzd", to="西安北", off_map=True,
         mids=["njn", "bbn"], service="express", dep=(540, 1000, 100), max_n=3),
    dict(dir="up", first="shhq", last="jnx", to="青岛", off_map=True,
         mids=["czb", "njn", "bbn", "xzd"], service="normal", dep=(480, 1020, 90), max_n=4),
    dict(dir="up", first="shhq", last="xzd",
         mids=["czb", "njn", "bbn", "szd"], service="normal", dep=(570, 1080, 80), max_n=3),
    dict(dir="up", first="shhq", last="njn",
         mids=["ksn", "szb", "wxd", "czb", "zjn"], service="normal", dep=(600, 1200, 60), max_n=5),
    dict(dir="up", first="xzd", frm="西安北", off_map=True, last="bjn",
         mids=["jnx", "tjn"], service="express", dep=(600, 1020, 100), max_n=3),
    dict(dir="up", first="njn", frm="杭州", off_map=True, last="bjn",
         mids=["cz", "bbn", "xzd", "jnx", "tjn"], service="normal", dep=(480, 1080, 70), max_n=4),
]


def build_candidates():
    """把模板展开为按发车时刻排列的候选列表。"""
    cands = []
    for tpl in TEMPLATES:
        start, end, step = tpl["dep"]
        stops = [tpl["first"]] + list(tpl["mids"]) + [tpl["last"]]
        t = start
        idx = 0
        while t <= end and idx < tpl["max_n"] * 6:
            cands.append(dict(tpl, dep_s=t * 60, stops=stops))
            t += step
            idx += 1
    random.shuffle(cands)
    return cands


def stops_to_raw(stops):
    """(sid, arr, dep) 绝对秒 -> JSON 停站（"HH:MM"，跨日直接用 >24 小时表示）。"""
    out = []
    n = len(stops)
    for i, (sid, arr, dep) in enumerate(stops):
        out.append({
            "sid": sid,
            "arr": lib.fmt_hhmm(arr) if i > 0 else None,
            "dep": lib.fmt_hhmm(dep) if i < n - 1 else None,
        })
    return out


def main():
    line, stations, station_arc, total_len = lib.load_line()

    # 载入真实车次作为底噪（含已接受的生成车，滚动追加）
    with open(lib.data_path("timetables", "real.json"), encoding="utf-8") as f:
        real_doc = json.load(f)
    existing = []
    for tr in real_doc["trains"]:
        existing.append((tr["code"], tr.get("dir", "down"), lib.normalize_stops(tr["stops"])))

    out = []
    next_odd = 4001   # 下行 G4xxx 奇数
    next_even = 4002  # 上行 G4xxx 偶数
    accepted = 0
    rejected = 0

    for cand in build_candidates():
        dep = cand["dep_s"]
        if dep < START_OK:
            continue
        stops = lib.build_schedule(dep, cand["stops"], station_arc, cand["service"],
                                   pace=1.08 if cand["service"] == "express" else 1.10)
        if stops[-1][1] > END_OK:
            rejected += 1
            continue
        if lib.has_conflict(cand["dir"], stops, station_arc, existing):
            rejected += 1
            continue
        if cand["dir"] == "down":
            code = "G%d" % next_odd
            next_odd += 2
        else:
            code = "G%d" % next_even
            next_even += 2
        existing.append((code, cand["dir"], stops))
        out.append({
            "code": code,
            "dir": cand["dir"],
            "type": pick_type(),
            "from": cand.get("frm", stations[cand["first"]]["name"]),
            "to": cand.get("to", stations[cand["last"]]["name"]),
            "off_map": bool(cand.get("off_map", False)),
            "express": False,
            "generated": True,
            "stops": stops_to_raw(stops),
        })
        accepted += 1

    # 夜间动卧（生成补充内容，跨天窗运行）
    sleepers = [
        ("D901", "down", "23:20", ["bjn", "njn", "shhq"], "北京南", "上海虹桥"),
        ("D903", "down", "23:50", ["bjn", "njn", "shhq"], "北京南", "上海虹桥"),
        ("D902", "up",   "23:10", ["shhq", "njn", "bjn"], "上海虹桥", "北京南"),
        ("D904", "up",   "23:35", ["shhq", "njn", "bjn"], "上海虹桥", "北京南"),
    ]
    for code, direction, dep_s, stop_sids, frm, to in sleepers:
        dep = lib.parse_hhmm(dep_s)
        stops = lib.build_schedule(dep, stop_sids, station_arc, "sleeper",
                                   dwell={"njn": 8}, pace=1.05)
        if lib.has_conflict(direction, stops, station_arc, existing):
            continue
        existing.append((code, direction, stops))
        out.append({
            "code": code, "dir": direction, "type": "CRH2E",
            "from": frm, "to": to, "off_map": False,
            "express": False, "generated": True,
            "stops": stops_to_raw(stops),
        })

    doc = {
        "note": "程序生成的补充车流（跨线车/临客/夜间动卧），车次号为虚构临客号段；已做同方向追踪间隔检查。",
        "trains": out,
    }
    json.dump(doc, sys.stdout, ensure_ascii=False, indent=2)
    print()
    total = len(real_doc["trains"]) + len(out)
    print("[统计] 生成 %d 趟（拒绝 %d 次冲突/超窗），全线共 %d 趟/日"
          % (len(out), rejected, total), file=sys.stderr)
    hist = {}
    for tr in out:
        h = int(lib.parse_hhmm([s for s in tr["stops"] if s.get("dep")][0]["dep"]) // 3600) % 24
        hist[h] = hist.get(h, 0) + 1
    for h in sorted(hist):
        print("  %02d 时 + %d 趟" % (h, hist[h]), file=sys.stderr)


if __name__ == "__main__":
    main()

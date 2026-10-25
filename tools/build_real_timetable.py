# -*- coding: utf-8 -*-
"""整理京沪高铁代表性真实车次，把时刻表 JSON 打印到标准输出。

车次号、停站方案与发车时段按公开资料整理；具体到发时刻为按区段长度与
服务等级推算的整理值（与实际运营可能有出入，可在本文件调整后重新生成）。

用法：在项目根目录运行
  python tools/build_real_timetable.py > data/timetables/real.json
"""
import json
import sys

import timetable_lib as lib

# (code, dep, stops[按运行方向], service, type, 其余可选: frm/to/off_map/express/dwell/pace)
T = []


def add(code, dep, stops, service, typ, **kw):
    T.append(dict(code=code, dep=dep, stops=stops, service=service, type=typ, **kw))


# ---------- 下行（北京南 → 上海虹桥方向）----------
# 大站直达 / 少停 express
add("G1",  "07:00", ["bjn", "njn", "shhq"], "express", "CR400AF-BZ", express=True)
add("G5",  "08:00", ["bjn", "njn", "shhq"], "express", "CR400BF-BZ", express=True)
add("G7",  "09:00", ["bjn", "jnx", "njn", "shhq"], "express", "CR400AF-BZ", express=True)
add("G9",  "10:00", ["bjn", "njn", "shhq"], "express", "CR400BF-BZ", express=True)
add("G11", "11:00", ["bjn", "njn", "shhq"], "express", "CR400AF-BZ", express=True)
add("G13", "12:00", ["bjn", "njn", "shhq"], "express", "CR400BF-BZ", express=True)
add("G3",  "14:00", ["bjn", "jnx", "njn", "shhq"], "express", "CR400AF-BZ", express=True)
add("G15", "14:40", ["bjn", "njn", "shhq"], "express", "CR400AF-BZ", express=True)
add("G17", "15:20", ["bjn", "njn", "shhq"], "express", "CR400BF-BZ", express=True)
add("G19", "16:00", ["bjn", "njn", "shhq"], "express", "CR400AF-BZ", express=True)
add("G21", "16:40", ["bjn", "njn", "shhq"], "express", "CR400BF-BZ", express=True)
add("G23", "17:20", ["bjn", "jnx", "njn", "shhq"], "express", "CR400BF-BZ", express=True)
add("G25", "18:00", ["bjn", "njn", "shhq"], "express", "CR400AF-BZ", express=True)
add("G27", "18:40", ["bjn", "njn", "shhq"], "express", "CR400BF-BZ", express=True, pace=1.0)

# 多停 normal/slow
add("G101", "06:20", ["bjn", "lf", "tjn", "czx", "dzn", "jnx", "ta", "qfd", "zz", "xzd", "bbn", "njn", "czb", "wxd", "szb", "shhq"], "normal", "CRH380BL")
add("G105", "07:30", ["bjn", "tjn", "jnx", "xzd", "bbn", "njn", "zjn", "czb", "szb", "shhq"], "normal", "CRH380B")
add("G109", "08:15", ["bjn", "tjn", "dzn", "jnx", "ta", "qfd", "xzd", "njn", "czb", "wxd", "ksn", "shhq"], "normal", "CRH380A")
add("G111", "09:20", ["bjn", "jnx", "xzd", "bbn", "njn", "czb", "szb", "shhq"], "normal", "CR400AF-A")
add("G115", "10:30", ["bjn", "tjn", "czx", "jnx", "qfd", "xzd", "szd", "bbn", "njn", "zjn", "wxd", "ksn", "shhq"], "normal", "CRH380B")
add("G119", "12:40", ["bjn", "tjn", "jnx", "ta", "xzd", "njn", "czb", "szb", "shhq"], "normal", "CRH380BL")
add("G123", "13:30", ["bjn", "czx", "dzn", "jnx", "qfd", "zz", "xzd", "bbn", "dy", "njn", "zjn", "dyb", "czb", "wxd", "szb", "ksn", "shhq"], "slow", "CRH380A")
add("G127", "15:10", ["bjn", "tjn", "jnx", "xzd", "njn", "czb", "ksn", "shhq"], "normal", "CR400BF-A")
add("G131", "16:30", ["bjn", "czx", "jnx", "ta", "qfd", "xzd", "szd", "bbn", "njn", "czb", "wxd", "szb", "shhq"], "normal", "CRH380B")
add("G135", "18:00", ["bjn", "tjn", "jnx", "xzd", "bbn", "njn", "szb", "shhq"], "normal", "CRH380AL")
add("G139", "19:00", ["bjn", "jnx", "xzd", "njn", "czb"], "normal", "CRH380A", to="常州北")

# 区间终到 / 跨线离图
add("G33",  "08:45", ["bjn", "jnx", "njn"], "express", "CR400BF", to="杭州东", off_map=True, express=True)
add("G167", "12:15", ["bjn", "lf", "tjn", "czx", "jnx", "xzd", "bbn", "njn"], "normal", "CRH380B")
add("G173", "17:20", ["bjn", "tjn", "jnx", "ta", "qfd", "zz", "xzd"], "normal", "CRH380A")
add("G226", "15:00", ["jnx", "ta", "xzd", "bbn", "njn", "czb", "szb", "shhq"], "normal", "CRH380B", frm="青岛", off_map=True)

# ---------- 上行（上海虹桥 → 北京南方向）----------
add("G2",  "07:00", ["shhq", "njn", "bjn"], "express", "CR400BF-BZ", express=True)
add("G6",  "08:00", ["shhq", "njn", "jnx", "bjn"], "express", "CR400AF-BZ", express=True)
add("G8",  "09:00", ["shhq", "njn", "bjn"], "express", "CR400AF-BZ", express=True)
add("G10", "10:00", ["shhq", "njn", "bjn"], "express", "CR400BF-BZ", express=True)
add("G12", "11:00", ["shhq", "njn", "bjn"], "express", "CR400AF-BZ", express=True)
add("G16", "12:00", ["shhq", "njn", "bjn"], "express", "CR400BF-BZ", express=True)
add("G18", "13:00", ["shhq", "njn", "bjn"], "express", "CR400AF-BZ", express=True)
add("G20", "14:00", ["shhq", "njn", "bjn"], "express", "CR400BF-BZ", express=True)
add("G22", "15:00", ["shhq", "njn", "jnx", "bjn"], "express", "CR400AF-BZ", express=True)
add("G24", "16:00", ["shhq", "njn", "bjn"], "express", "CR400BF-BZ", express=True)
add("G26", "17:00", ["shhq", "njn", "bjn"], "express", "CR400AF-BZ", express=True)
add("G4",  "18:00", ["shhq", "njn", "bjn"], "express", "CR400BF-BZ", express=True, pace=1.0)

add("G102", "06:35", ["shhq", "szb", "wxd", "czb", "njn", "bbn", "xzd", "jnx", "tjn", "bjn"], "normal", "CRH380B")
add("G108", "08:20", ["shhq", "ksn", "szb", "wxd", "czb", "zjn", "njn", "bbn", "xzd", "jnx", "czx", "tjn", "bjn"], "normal", "CRH380A")
add("G112", "09:40", ["shhq", "czb", "njn", "bbn", "xzd", "jnx", "tjn", "bjn"], "normal", "CRH380BL")
add("G120", "11:10", ["shhq", "njn", "bbn", "xzd", "jnx", "bjn"], "normal", "CR400AF-A")
add("G124", "12:30", ["shhq", "wxd", "czb", "zjn", "njn", "dy", "bbn", "xzd", "qfd", "ta", "jnx", "dzn", "czx", "tjn", "lf", "bjn"], "slow", "CRH380A")
add("G132", "14:00", ["shhq", "szb", "njn", "xzd", "jnx", "tjn", "bjn"], "normal", "CRH380B")
add("G140", "15:30", ["shhq", "czb", "njn", "bbn", "szd", "xzd", "zz", "qfd", "ta", "jnx", "czx", "tjn", "bjn"], "normal", "CRH380BL")
add("G148", "17:10", ["shhq", "njn", "xzd", "jnx", "tjn", "bjn"], "normal", "CRH380AL")
add("G156", "19:00", ["shhq", "njn", "bbn", "xzd"], "normal", "CRH380A", to="济南西")
add("G164", "20:00", ["shhq", "ksn", "szb", "wxd", "czb", "zjn"], "normal", "CRH380B")

add("G150", "18:40", ["njn", "cz", "bbn", "xzd", "jnx", "tjn", "bjn"], "normal", "CRH380B", frm="杭州", off_map=True)
add("G192", "19:30", ["xzd", "jnx", "tjn", "bjn"], "express", "CR400AF", frm="西安北", off_map=True, express=True)


def main():
    line, stations, station_arc, total_len = lib.load_line()
    warnings = []
    out = []
    codes = set()
    for tr in T:
        code = tr["code"]
        if code in codes:
            warnings.append("车次号重复：%s" % code)
            continue
        codes.add(code)
        direction = "down" if tr["stops"][0] == "bjn" else "up"
        first_sid = tr["stops"][0]
        last_sid = tr["stops"][-1]
        dep = lib.parse_hhmm(tr["dep"])
        pace = tr.get("pace", 1.06 if tr["service"] == "express" else 1.10)
        stops = lib.build_schedule(dep, tr["stops"], station_arc, tr["service"],
                                   dwell=tr.get("dwell"), pace=pace)
        lib.validate_schedule(stops, station_arc, code, warnings)
        if stops[-1][1] > 86340.0:  # 23:59 前必须终到（动卧由生成器负责）
            warnings.append("%s 终到时刻越过天窗（%s）" % (code, lib.fmt_hhmm(stops[-1][1])))
        out.append({
            "code": code,
            "dir": direction,
            "type": tr["type"],
            "from": tr.get("frm", stations[first_sid]["name"]),
            "to": tr.get("to", stations[last_sid]["name"]),
            "off_map": bool(tr.get("off_map", False)),
            "express": bool(tr.get("express", False)),
            "generated": False,
            "stops": [{"sid": s, "arr": lib.hhmm_or_none(a if i > 0 else None),
                       "dep": lib.hhmm_or_none(d if i < len(stops) - 1 else None)}
                      for i, (s, a, d) in enumerate(stops)]
        })

    doc = {
        "note": "车次/停站按公开时刻表资料整理，具体到发时刻为按区段推算的整理值，可能存在偏差；可修改本脚本后重新生成。",
        "trains": out,
    }
    json.dump(doc, sys.stdout, ensure_ascii=False, indent=2)
    print()
    for w in warnings:
        print("[警告] %s" % w, file=sys.stderr)


if __name__ == "__main__":
    main()

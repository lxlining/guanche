# -*- coding: utf-8 -*-
"""为货运专线生成示意货车车流 -> 标准输出 JSON。

12306 无货运数据；货车按线路密度程序生成（固定种子可复现），
车次 H5xxxx（纯示意号段），均速约 75km/h，停站少。
用法：python tools/gen_freight.py > data/timetables/freight.json
"""
import json
import random
import sys

import timetable_lib as lib

random.seed(41777)

# line_id -> (每日对数, 车型说明)
PLAN = {
    "daqin_freight": (9, "单元万吨煤列（和谐 HXD1 + C80）"),
    "haoji_freight": (6, "重载煤列（和谐 HXD2 + C96）"),
    "shuohuang_freight": (6, "神华重载煤列"),
    "wari_freight": (4, "万吨煤列"),
    "baoxi_freight": (4, "客货共线货车"),
    "taizhongyin_freight": (4, "客货共线货车"),
}

FREIGHT_TYPE = "FREIGHT"


def fmt(sec):
    return "%02d:%02d" % (int(sec // 3600) % 48, int(sec % 3600 // 60))


def main():
    all_lines = lib.load_all_lines()
    out = []
    seq = 51001
    for line_id, (pairs, note) in PLAN.items():
        if line_id not in all_lines:
            continue
        doc, stations, station_arc, total = all_lines[line_id]
        order = doc["stations"]
        n = len(order)
        for k in range(pairs):
            # 重去（正方向）+ 空回（反方向），错开发车时刻
            dep0 = 5 * 3600 + k * 7200 + random.randint(-600, 600)
            for direction in (0, 1):
                stops_ids = [order[i]["id"] for i in (range(n) if direction == 0 else range(n - 1, -1, -1))]
                # 中途加一站：约中点的站
                if n >= 4:
                    mid = stops_ids[len(stops_ids) // 2]
                    seq_ids = [stops_ids[0], mid, stops_ids[-1]]
                else:
                    seq_ids = [stops_ids[0], stops_ids[-1]]
                dep = dep0 + (0 if direction == 0 else random.randint(3, 6) * 3600)
                schedule = lib.build_schedule(dep, seq_ids, station_arc, "sleeper",
                                              dwell={mid: 25} if n >= 4 else None, pace=1.0)
                stops_json = []
                m = len(schedule)
                for i, (sid, a, d) in enumerate(schedule):
                    stops_json.append({
                        "sid": sid,
                        "arr": fmt(a) if i > 0 else None,
                        "dep": fmt(d) if i < m - 1 else None,
                    })
                out.append({
                    "code": "H%d" % seq,
                    "line": line_id,
                    "legs": [{"line": line_id, "i0": 0, "i1": m - 1}],
                    "type": FREIGHT_TYPE,
                    "from": order[0]["name"] if direction == 0 else order[-1]["name"],
                    "to": order[-1]["name"] if direction == 0 else order[0]["name"],
                    "off_map": False,
                    "express": False,
                    "generated": True,
                    "freight": True,
                    "source": "generated_freight",
                    "note": note,
                    "stops": stops_json,
                })
                seq += 2
    json.dump({"note": "货运示意车流（程序生成，非真实时刻）", "trains": out},
              sys.stdout, ensure_ascii=False, indent=2)
    print()
    print("[统计] 货运示意车流 %d 列" % len(out), file=sys.stderr)


if __name__ == "__main__":
    main()

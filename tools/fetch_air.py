# -*- coding: utf-8 -*-
"""航空数据管线：下载机场/航线开放数据，过滤中国国内干线，
输出 data/air/aviation.json。

零文件 I/O（与 osm_geometry.py 同规范）：Python 只走 stdin/stdout，
文件落盘由 tools/fetch_air_all.sh 以 bash 重定向完成（tmp+mv 原子写）。

数据源：
  - 机场：OurAirports airports.csv（活跃维护，含大兴 PKX）
  - 航线：OpenFlights routes.dat（2014 年前后快照，覆盖国内主要干线）
  - 航空公司：OpenFlights airlines.dat

用法（通常经 tools/fetch_air_all.sh 调用）:
  python tools/fetch_air.py --fetch airports > tools/cacheair/airports.cache
  python tools/fetch_air.py --build <a.cache> <al.cache> <r.cache> > data/air/aviation.json
"""
import csv
import io
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from collections import defaultdict

GH = "https://raw.githubusercontent.com/jpatokal/openflights/master/data/"
GH_MIRRORS = [
    "https://gh-proxy.com/" + GH,
    "https://ghproxy.net/" + GH,
    GH,
]
# 数据源与下载地址（key 必须来自本表）
URLS = {
    "airports": ["https://davidmegginson.github.io/ourairports-data/airports.csv"],
    "airlines": [m + "airlines.dat" for m in GH_MIRRORS],
    "routes": [m + "routes.dat" for m in GH_MIRRORS],
}

# 中国主要机场中文名（IATA -> [中文名, 城市, 是否枢纽]）
CN_AIRPORTS = {
    "PEK": ["北京首都国际机场", "北京", 1], "PKX": ["北京大兴国际机场", "北京", 1],
    "SHA": ["上海虹桥国际机场", "上海", 1], "PVG": ["上海浦东国际机场", "上海", 1],
    "CAN": ["广州白云国际机场", "广州", 1], "SZX": ["深圳宝安国际机场", "深圳", 1],
    "CTU": ["成都双流国际机场", "成都", 1], "TFU": ["成都天府国际机场", "成都", 1],
    "KMG": ["昆明长水国际机场", "昆明", 1], "XIY": ["西安咸阳国际机场", "西安", 1],
    "CKG": ["重庆江北国际机场", "重庆", 1], "HGH": ["杭州萧山国际机场", "杭州", 1],
    "NKG": ["南京禄口国际机场", "南京", 1], "WUH": ["武汉天河国际机场", "武汉", 1],
    "CSX": ["长沙黄花国际机场", "长沙", 1], "XMN": ["厦门高崎国际机场", "厦门", 1],
    "TAO": ["青岛胶东国际机场", "青岛", 1], "DLC": ["大连周水子国际机场", "大连", 0],
    "SHE": ["沈阳桃仙国际机场", "沈阳", 1], "HRB": ["哈尔滨太平国际机场", "哈尔滨", 1],
    "SYX": ["三亚凤凰国际机场", "三亚", 1], "HAK": ["海口美兰国际机场", "海口", 1],
    "TSN": ["天津滨海国际机场", "天津", 1], "CGO": ["郑州新郑国际机场", "郑州", 1],
    "TNA": ["济南遥墙国际机场", "济南", 0], "FOC": ["福州长乐国际机场", "福州", 1],
    "KWE": ["贵阳龙洞堡国际机场", "贵阳", 1], "NNG": ["南宁吴圩国际机场", "南宁", 0],
    "LHW": ["兰州中川国际机场", "兰州", 0], "URC": ["乌鲁木齐地窝堡国际机场", "乌鲁木齐", 1],
    "LXA": ["拉萨贡嘎国际机场", "拉萨", 0], "XNN": ["西宁曹家堡国际机场", "西宁", 0],
    "INC": ["银川河东国际机场", "银川", 0], "HET": ["呼和浩特白塔国际机场", "呼和浩特", 0],
    "NGB": ["宁波栎社国际机场", "宁波", 0], "WUX": ["无锡硕放机场", "无锡", 0],
    "HFE": ["合肥新桥国际机场", "合肥", 0], "TYN": ["太原武宿国际机场", "太原", 0],
    "SJW": ["石家庄正定国际机场", "石家庄", 0], "SWA": ["揭阳潮汕国际机场", "揭阳", 0],
    "ZUH": ["珠海金湾机场", "珠海", 0], "JJN": ["泉州晋江国际机场", "泉州", 0],
    "KHN": ["南昌昌北国际机场", "南昌", 0], "YNT": ["烟台蓬莱国际机场", "烟台", 0],
    "WEH": ["威海大水泊机场", "威海", 0], "HLD": ["海拉尔东山机场", "呼伦贝尔", 0],
    "EGO": ["鄂尔多斯伊金霍洛机场", "鄂尔多斯", 0], "BAV": ["包头东河机场", "包头", 0],
    "YIH": ["宜昌三峡机场", "宜昌", 0], "ENH": ["恩施许家坪机场", "恩施", 0],
    "JZH": ["九寨黄龙机场", "九寨沟", 0], "LZO": ["泸州云龙机场", "泸州", 0],
    "PZI": ["攀枝花保安营机场", "攀枝花", 0], "XIC": ["西昌青山机场", "西昌", 0],
    "LJG": ["丽江三义国际机场", "丽江", 0], "DLU": ["大理荒草坝机场", "大理", 0],
    "JHG": ["西双版纳嘎洒国际机场", "西双版纳", 0], "KRL": ["库尔勒机场", "库尔勒", 0],
    "KHG": ["喀什国际机场", "喀什", 0], "AKU": ["阿克苏机场", "阿克苏", 0],
    "HTN": ["和田机场", "和田", 0], "YIN": ["伊宁机场", "伊宁", 0],
    "AAT": ["阿勒泰机场", "阿勒泰", 0],
    "ZHY": ["中卫沙坡头机场", "中卫", 0], "HMI": ["哈密机场", "哈密", 0],
    "KRY": ["克拉玛依机场", "克拉玛依", 0], "BHY": ["北海福成机场", "北海", 0],
    "WUS": ["武夷山机场", "南平", 0], "TCZ": ["腾冲驼峰机场", "腾冲", 0],
    "LUM": ["芒市机场", "德宏", 0], "JDG": ["张家界荷花国际机场", "张家界", 0],
    "DAX": ["达州河市机场", "达州", 0], "GYS": ["广元盘龙机场", "广元", 0],
    "NAO": ["南充高坪机场", "南充", 0], "BZX": ["巴中恩阳机场", "巴中", 0],
    "YBP": ["宜宾菜坝机场", "宜宾", 0], "AQG": ["安庆天柱山机场", "安庆", 0],
    "FUG": ["阜阳西郊机场", "阜阳", 0], "JUZ": ["衢州机场", "衢州", 0],
    "YIW": ["义乌机场", "义乌", 0], "HYN": ["台州路桥机场", "台州", 0],
    "HSN": ["舟山普陀山机场", "舟山", 0], "RIZ": ["日照山字河机场", "日照", 0],
    "LYI": ["临沂启阳机场", "临沂", 0], "JGS": ["赣州黄金机场", "赣州", 0],
    "SHS": ["荆州沙市机场", "荆州", 0], "UYN": ["榆林榆阳机场", "榆林", 0],
    "ENY": ["延安二十里堡机场", "延安", 0], "HZG": ["汉中城固机场", "汉中", 0],
    "AVK": ["安康机场", "安康", 0], "DAT": ["大同云冈机场", "大同", 0],
    "YCU": ["运城张孝机场", "运城", 0], "LFQ": ["临汾尧都机场", "临汾", 0],
    "CHG": ["朝阳机场", "朝阳", 0], "JNZ": ["锦州湾机场", "锦州", 0],
    "TGO": ["通辽机场", "通辽", 0], "RHT": ["赤峰玉龙机场", "赤峰", 0],
    "WLN": ["乌兰浩特机场", "乌兰浩特", 0], "ZAT": ["昭通机场", "昭通", 0],
    "LNL": ["临沧机场", "临沧", 0], "WNS": ["文山砚山机场", "文山", 0],
    "BSD": ["保山云瑞机场", "保山", 0], "JMJ": ["澜沧景迈机场", "普洱", 0],
    "KGT": ["康定机场", "康定", 0], "YUS": ["玉树巴塘机场", "玉树", 0],
}

# 主要航司（IATA 两字码 -> 中文名）
CN_AIRLINES = {
    "CA": "中国国际航空", "MU": "中国东方航空", "CZ": "中国南方航空",
    "HU": "海南航空", "3U": "四川航空", "ZH": "深圳航空", "MF": "厦门航空",
    "FM": "上海航空", "GS": "天津航空", "SC": "山东航空", "HO": "吉祥航空",
    "KN": "中国联合航空", "G5": "华夏航空", "GJ": "长龙航空", "EU": "成都航空",
    "TV": "西藏航空", "PN": "西部航空", "UQ": "乌鲁木齐航空", "8L": "祥鹏航空",
    "DR": "瑞丽航空", "CN": "大新华航空", "OQ": "重庆航空", "AQ": "北部湾航空",
}

AIRLINE_COLORS = ["#e84d4d", "#3f7fe0", "#38b27a", "#e8a33d", "#9b59d0",
                  "#e8734d", "#38b2c4", "#d04a96", "#6f9e3d", "#c45a9e"]

FETCH_TIMEOUT = 180

# 下载目标白名单（固定 https 主机，杜绝 SSRF）
ALLOWED_HOSTS = frozenset([
    "davidmegginson.github.io",
    "raw.githubusercontent.com",
    "gh-proxy.com",
    "ghproxy.net",
])


def _safe_url(url):
    parts = urllib.parse.urlparse(url)
    if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS:
        raise ValueError("blocked non-allowlist url: %s" % url[:60])
    return url


def fetch_to_stdout(key):
    """下载单个数据源写到 stdout（零文件 I/O，落盘由 bash 重定向完成）。
    镜像回退链：gh-proxy.com → ghproxy.net → 直连。"""
    for url in URLS[key]:
        try:
            req = urllib.request.Request(_safe_url(url), headers={
                "User-Agent": "guanche-railwatch/1.0 (aviation data pipeline)"})
            with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as resp:
                data = resp.read()
            if len(data) < 1000:
                continue
            print("[fetch] %s: %.1f MB (%s)" % (key, len(data) / 1e6, url[:40]),
                  file=sys.stderr)
            sys.stdout.buffer.write(data)
            return 0
        except Exception as exc:
            print("[fetch] %s 失败: %s (%s)" % (key, exc, url[:40]), file=sys.stderr)
            time.sleep(3)
    return 1


def parse_csv(data):
    text = data.decode("utf-8", errors="replace")
    return list(csv.reader(io.StringIO(text)))


def build(json_in, al_in, rt_in):
    """从三份缓存字节流构建 aviation JSON 结构。"""
    out = {"airports": [], "airlines": [], "routes": []}

    rows = parse_csv(json_in)
    for r in rows[1:]:
        if len(r) < 18 or r[8] != "CN":
            continue
        iata = r[13]
        if iata not in CN_AIRPORTS:
            continue
        if r[2] in ("closed", "heliport", "balloonport", "seaplane_base"):
            continue
        try:
            lon, lat = float(r[5]), float(r[4])
        except ValueError:
            continue
        cn = CN_AIRPORTS[iata]
        out["airports"].append({
            "iata": iata, "name": cn[0], "city": cn[1],
            "major": cn[2], "lon": lon, "lat": lat,
        })

    if al_in is not None:
        seen_al = set()
        for r in parse_csv(al_in)[1:]:
            if len(r) < 8:
                continue
            code = r[3] if r[3] not in ("", "\\N") else ""
            if code in CN_AIRLINES and code not in seen_al:
                seen_al.add(code)
                out["airlines"].append({"code": code, "name": CN_AIRLINES[code]})

    color_map = {}
    for i, a in enumerate(out["airlines"]):
        color_map[a["code"]] = AIRLINE_COLORS[i % len(AIRLINE_COLORS)]
        a["color"] = AIRLINE_COLORS[i % len(AIRLINE_COLORS)]

    if rt_in is None:
        sys.exit("[build] 航线数据不可用")
    known_ap = {a["iata"] for a in out["airports"]}
    known_al = {a["code"] for a in out["airlines"]}
    route_count = defaultdict(int)
    for r in parse_csv(rt_in)[1:]:
        if len(r) < 8:
            continue
        al, src, dst, cs = r[0], r[2], r[4], r[6]
        if cs == "Y":
            continue  # 代码共享去重
        if src not in known_ap or dst not in known_ap or src == dst:
            continue
        if al not in known_al:
            continue
        route_count[(al, src, dst)] += 1
    for (al, src, dst), cnt in route_count.items():
        out["routes"].append({
            "airline": al, "from": src, "to": dst,
            "daily": min(6, max(2, cnt * 2)),
        })

    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    print("[air] 机场 %d · 航司 %d · 航线 %d"
          % (len(out["airports"]), len(out["airlines"]), len(out["routes"])),
          file=sys.stderr)


def _safe_cache_path(p):
    """构建输入路径校验：必须位于 tools/cacheair/ 下、以 .cache 结尾、
    不含 .. 穿越（防 argv 任意文件读取）。返回规范化绝对路径。"""
    norm = os.path.normpath(os.path.abspath(p))
    allowed_dir = os.path.normpath(os.path.abspath("tools/cacheair"))
    parts = p.replace("\\", "/").split("/")
    if (not norm.startswith(allowed_dir + os.sep)
            or not norm.endswith(".cache")
            or ".." in parts):
        sys.exit("[build] 拒绝缓存路径（须为 tools/cacheair/*.cache）: %s" % p)
    return norm


def main():
    args = sys.argv[1:]
    if len(args) >= 2 and args[0] == "--fetch":
        key = args[1]
        if key not in URLS:
            sys.exit("[fetch] 未知数据源: %s" % key)
        sys.exit(fetch_to_stdout(key))
    if len(args) >= 4 and args[0] == "--build":
        ap_path = _safe_cache_path(args[1])
        with open(ap_path, "rb") as f:
            ap = f.read()
        al = rt = None
        if args[2] != "-":
            with open(_safe_cache_path(args[2]), "rb") as f:
                al = f.read()
        if args[3] != "-":
            with open(_safe_cache_path(args[3]), "rb") as f:
                rt = f.read()
        build(ap, al, rt)
        return
    sys.exit("用法: fetch_air.py --fetch <airports|airlines|routes>  |  "
             "--build <airports.cache> <airlines.cache> <routes.cache>")


if __name__ == "__main__":
    main()

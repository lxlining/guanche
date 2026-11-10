# -*- coding: utf-8 -*-
"""批量用 OSM 真实铁路线形替换线路近似线形（Overpass API）。

本工具自身零文件 I/O：线路文档与 OSM 缓存均从 stdin 读入，
结果只写 stdout，文件持久化全部由 bash 重定向完成。

子命令：
  fetch <line_id> [pair]  stdin= 线路 JSON；向 Overpass 抓该线包围盒
                          （或第 pair 个站对的包围盒）内 railway=rail way
  build <line_id>         stdin= 线路 JSON 与 OSM 缓存 JSON 顺序拼接；
                          输出整份线路 JSON

build 流程（走廊排序链式拼接，天然免疫 OSM 碎片化与平行线干扰）：
  1. 按线路等级过滤 way 子图（高铁/城际保留高等级与匿名 way，普速反之）；
  2. 以旧线形为走廊参考，仅保留中点距走廊 ≤12km 的碎片，按首节点去重；
  3. 碎片按走廊投影排序，贪心链接：窗口内优先同名/匿名碎片、
     取端点最近者并按需翻转方向，窗口外直连跳过缺口；
  4. 站序单调向前吸附到链上最近顶点；站坐标偏差 >2km 时
     以 OSM 位置修正站坐标（km 不变）；
  5. 区段独立 Douglas-Peucker 简化（保住车站标记点），
     整线长度比校验，越界则原样输出旧文档。

安全约定：Overpass 仅允许白名单域名的 https 端点，请求前解析 DNS
并阻断私网/环回/链路本地地址；line_id 仅用于日志（仍做格式校验）。
"""
import heapq
import json
import math
import os
import re
import socket
import sys
import time
import urllib.parse
import urllib.request

import timetable_lib as lib

BBOX_PAD = 0.22          # 线路/站对包围格外扩（度）
SIMPLIFY_TOL_M = 120.0   # DP 简化容差
LEN_RATIO_MIN, LEN_RATIO_MAX = 0.55, 1.9   # 新旧整线长度比的安全区间

CORRIDOR_MAX_M = 12000.0   # 碎片中点距走廊的最大距离
CHAIN_GAP_M = 30000.0      # 链接相邻碎片的最大端点跳距
NAME_WINDOW_T = 0.08       # 同名优先的投影窗口宽度
COORD_FIX_M = 2000.0       # 站坐标修正阈值

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.osm.jp/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
]
ALLOWED_HOSTS = {"overpass-api.de", "overpass.kumi.systems", "overpass.osm.jp",
                 "overpass.private.coffee", "overpass.osm.ch"}
LINE_ID_RE = re.compile(r"^[a-z0-9_]{1,64}$")
PRIVATE_PREFIXES = ("10.", "192.168.", "169.254.", "127.", "0.",
                    "fc", "fd", "fe80", "::1")


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def eprint(*args):
    print(*args, file=sys.stderr)


def check_line_id(line_id):
    if not LINE_ID_RE.fullmatch(line_id):
        die("非法 line_id: %r" % line_id)
    return line_id


def check_url(url):
    """仅放行白名单 https 端点，且解析出的 IP 不得为私网/环回/链路本地。"""
    p = urllib.parse.urlparse(url)
    if p.scheme != "https" or p.hostname not in ALLOWED_HOSTS:
        raise ValueError("不在白名单内的 URL")
    for info in socket.getaddrinfo(p.hostname, 443):
        ip = str(info[4][0])
        if ip.startswith(PRIVATE_PREFIXES):
            raise ValueError("域名解析到非公网地址 %s" % ip)
    return url


def read_stdin_docs(n=None):
    """从 stdin 顺序 raw_decode JSON 文档；n=None 时读到流结束。"""
    text = sys.stdin.read()
    dec = json.JSONDecoder()
    pos = 0
    docs = []
    while True:
        while pos < len(text) and text[pos] in " \t\r\n":
            pos += 1
        if pos >= len(text):
            break
        if n is not None and len(docs) >= n:
            break
        doc, pos = dec.raw_decode(text, pos)
        docs.append(doc)
    return docs


def dist_m(a, b):
    return math.hypot((a[0] - b[0]) * lib.M_PER_DEG_LON, (a[1] - b[1]) * lib.M_PER_DEG_LAT)


def gc_m(a, b):
    """大圆距离（等距矩形近似）。"""
    dy = (a[1] - b[1]) * 110574.0
    dx = (a[0] - b[0]) * 111320.0 * math.cos(math.radians((a[1] + b[1]) * 0.5))
    return math.hypot(dx, dy)


# ---------- fetch ----------

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """禁止重定向：端点固定，重定向一律视为失败。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def overpass_post(query, timeout=150):
    """向白名单 Overpass 端点发查询。

    安全措施：端点为字面量常量；check_url 校验 https 协议 + 域名白名单 +
    DNS 解析结果非私网/环回/链路本地（防 SSRF 与 DNS rebinding）；
    _NoRedirect 禁止重定向。全部端点失败抛 RuntimeError。
    """
    body = urllib.parse.urlencode({"data": query}).encode("utf-8")
    last_err = None
    # 字面量端点（与 OVERPASS_ENDPOINTS 一致，供静态审查）
    for url in ("https://overpass-api.de/api/interpreter",
                "https://overpass.kumi.systems/api/interpreter",
                "https://overpass.osm.jp/api/interpreter",
                "https://overpass.private.coffee/api/interpreter",
                "https://overpass.osm.ch/api/interpreter"):
        try:
            check_url(url)
            req = urllib.request.Request(url, data=body, headers={
                "User-Agent": "guanche-railwatch/1.0 (timetable game data pipeline)"})
            with _OPENER.open(req, timeout=timeout) as resp:
                data = resp.read()
            doc = json.loads(data.decode("utf-8", errors="replace"))
            n_way = sum(1 for el in doc.get("elements", [])
                        if el.get("type") == "way")
            if n_way == 0:
                # 部分镜像只覆盖本区域（如 osm.ch 无中国数据），视为失败
                raise RuntimeError("实例返回 0 ways（可能无该区域数据）")
            return doc, n_way, len(data), url
        except Exception as exc:
            last_err = exc
            eprint("[fetch] %s 失败: %s" % (url, exc))
            time.sleep(2)
    raise RuntimeError("全部端点失败: %s" % last_err)


def cmd_fetch(line_id, pair_idx=None, station_idx=None):
    (line,) = read_stdin_docs(1)
    sts = line["stations"]
    if station_idx is not None:
        # 站级补抓：单站包围盒（keep-old 线走廊缺口修复用）
        if not (0 <= station_idx < len(sts)):
            die("station 越界: %s s=%d" % (line_id, station_idx))
        sel = [sts[station_idx]]
    elif pair_idx is None:
        sel = sts
    else:
        if not (0 <= pair_idx < len(sts) - 1):
            die("pair 越界: %s k=%d" % (line_id, pair_idx))
        sel = [sts[pair_idx], sts[pair_idx + 1]]
    lons = [float(s["lon"]) for s in sel]
    lats = [float(s["lat"]) for s in sel]
    # 包围格外扩可由 OSM_PAD 覆盖（keep-old 宽幅补抓用 0.35°，
    # 消除长站间距站对框之间的走廊缺口），钳制在 0.10~0.50 度
    try:
        pad = min(0.50, max(0.10, float(os.environ.get("OSM_PAD", BBOX_PAD))))
    except ValueError:
        pad = BBOX_PAD
    south, north = min(lats) - pad, max(lats) + pad
    west, east = min(lons) - pad, max(lons) + pad
    query = ("[out:json][timeout:120];"
             'way["railway"="rail"](%f,%f,%f,%f);out geom qt;'
             % (south, west, north, east))
    last_err = None
    for rnd in range(2):  # 快速失败：整体重跑兜底，不在单任务里久耗
        try:
            doc, n_way, nbytes, url = overpass_post(query)
            eprint("[fetch] %s[%s]: %d ways, %.1f MB (%s)"
                   % (line_id, "?" if pair_idx is None else pair_idx,
                      n_way, nbytes / 1e6, url))
            json.dump(doc, sys.stdout, ensure_ascii=False)
            return
        except Exception as exc:
            last_err = exc
            time.sleep(6 + 8 * rnd)
    die("[fetch] %s 全部端点失败: %s" % (line_id, last_err))


# ---------- 轨道图（缝合 + A*） ----------


class RailGraph:
    """OSM way 集合 -> 缝合后的轨道图（并查集 + 邻接表 + 网格吸附）。"""

    def __init__(self, doc):
        ways = []
        for el in doc.get("elements", []):
            if el.get("type") != "way":
                continue
            node_ids = el.get("nodes") or []
            geom = el.get("geometry") or []
            if len(node_ids) >= 2 and len(geom) >= 2 and len(node_ids) == len(geom):
                wname = str((el.get("tags") or {}).get("name", "") or "")
                ways.append((wname, node_ids,
                             [(float(p["lon"]), float(p["lat"])) for p in geom]))
        self.parent = {}

        def find(x):
            root = x
            while self.parent[root] != root:
                root = self.parent[root]
            while self.parent[x] != root:
                self.parent[x], x = root, self.parent[x]
            return root
        self._find = find

        def union(a, b=None):
            for v in ((a,) if b is None else (a, b)):
                self.parent.setdefault(v, v)
            if b is None:
                return
            ra, rb = find(a), find(b)
            if ra != rb:
                self.parent[ra] = rb

        self.nodes = {}
        stitch_edges = []
        name_ends = {}
        for wname, nids, coords in ways:
            for nid, c in zip(nids, coords):
                self.nodes[nid] = c
                union(nid)
            for a, b in zip(nids, nids[1:]):
                union(a, b)
            if wname and len(nids) >= 2:
                name_ends.setdefault(wname, []).append((nids[0], nids[-1]))
        for wname, ends in name_ends.items():
            pts = []
            for wid, (a, b) in enumerate(ends):
                pts.append((a, wid))
                pts.append((b, wid))
            cell = 0.05
            buckets = {}
            for i, (nid, wid) in enumerate(pts):
                lon, lat = self.nodes[nid]
                buckets.setdefault((int(lon / cell), int(lat / cell)), []).append(i)
            nearest = [None] * len(pts)
            for i, (nid, wid) in enumerate(pts):
                lon, lat = self.nodes[nid]
                bx, by = int(lon / cell), int(lat / cell)
                bd, bj = 5000.0, -1
                for gx in (bx - 1, bx, bx + 1):
                    for gy in (by - 1, by, by + 1):
                        for j in buckets.get((gx, gy), ()):
                            if j == i:
                                continue
                            nid2, wj = pts[j]
                            if wj == wid:
                                continue
                            d = dist_m(self.nodes[nid], self.nodes[nid2])
                            if d < bd:
                                bd, bj = d, j
                nearest[i] = (bj, bd)
            for i in range(len(pts)):
                j, di = nearest[i]
                if j < 0:
                    continue
                bj, _dj = nearest[j]
                if bj == i:
                    a, wi = pts[i]
                    b, wj = pts[j]
                    if a != b and wi != wj:
                        union(a, b)
                        stitch_edges.append((a, b, di))
        all_ends = []
        for wname, end_pairs in name_ends.items():
            for a, b in end_pairs:
                all_ends.append((a, wname))
                all_ends.append((b, wname))
        cell2 = 0.01
        buckets2 = {}
        for i, (nid, wname) in enumerate(all_ends):
            lon, lat = self.nodes[nid]
            buckets2.setdefault((int(lon / cell2), int(lat / cell2)), []).append(i)
        near2 = [None] * len(all_ends)
        for i, (nid, wname) in enumerate(all_ends):
            lon, lat = self.nodes[nid]
            bx, by = int(lon / cell2), int(lat / cell2)
            bd, bj = 800.0, -1
            for gx in (bx - 1, bx, bx + 1):
                for gy in (by - 1, by, by + 1):
                    for j in buckets2.get((gx, gy), ()):
                        if j == i:
                            continue
                        nid2, _w2 = all_ends[j]
                        d = dist_m(self.nodes[nid], self.nodes[nid2])
                        if d < bd:
                            bd, bj = d, j
            near2[i] = (bj, bd)
        for i in range(len(all_ends)):
            j, di = near2[i]
            if j < 0:
                continue
            bj, _dj = near2[j]
            if bj == i:
                a, _w1 = all_ends[i]
                b, _w2 = all_ends[j]
                if a != b:
                    union(a, b)
                    stitch_edges.append((a, b, di))
        self.adj = {}
        for wname, nids, coords in ways:
            for (a, ca), (b, cb) in zip(zip(nids, coords), zip(nids[1:], coords[1:])):
                if find(a) != find(b):
                    continue
                w = dist_m(ca, cb)
                if w <= 0:
                    continue
                self.adj.setdefault(a, []).append((b, w))
                self.adj.setdefault(b, []).append((a, w))
        for a, b, d in stitch_edges:
            self.adj.setdefault(a, []).append((b, d))
            self.adj.setdefault(b, []).append((a, d))
        self.grid = {}
        cs = 0.01
        for nid, (lon, lat) in self.nodes.items():
            self.grid.setdefault((int(lon / cs), int(lat / cs)), []).append(nid)
        self._cs = cs

    def comp_of(self, nid):
        return self._find(nid)

    def nearest_nodes(self, pt, max_m=18000.0):
        cs = self._cs
        bx, by = int(pt[0] / cs), int(pt[1] / cs)
        out = []
        radius = 2
        while radius <= 40:
            for gx in range(bx - radius, bx + radius + 1):
                for gy in range(by - radius, by + radius + 1):
                    for nid in self.grid.get((gx, gy), ()):
                        d = dist_m(pt, self.nodes[nid])
                        if d <= max_m:
                            out.append((nid, d))
            if out:
                break
            radius = radius * 2
        out.sort(key=lambda t: t[1])
        return out[:12]


def astar_path(g, src, dst):
    """缝合图内 A*（启发式 = 大圆距离，可采纳）。"""
    if src == dst:
        return [src]
    goal_pos = g.nodes[dst]
    open_h = [(0.0, src)]
    g_score = {src: 0.0}
    came = {}
    closed = set()
    while open_h:
        _, cur = heapq.heappop(open_h)
        if cur == dst:
            path = [cur]
            while cur in came:
                cur = came[cur]
                path.append(cur)
            return path[::-1]
        if cur in closed:
            continue
        closed.add(cur)
        base = g_score[cur]
        for nbr, w in g.adj.get(cur, ()):
            ng = base + w
            if ng < g_score.get(nbr, 1e18):
                g_score[nbr] = ng
                came[nbr] = cur
                heapq.heappush(open_h, (ng + gc_m(g.nodes[nbr], goal_pos), nbr))
    return None


def old_segment(line, sid_a, sid_b):
    """从旧线形中提取 sid_a..sid_b 的区段（含端点）。"""
    geo = line.get("geometry", [])
    ia = ib = -1
    for i, p in enumerate(geo):
        if len(p) > 2 and p[2]:
            if p[2] == sid_a and ia < 0:
                ia = i
            elif p[2] == sid_b and ia >= 0:
                ib = i
                break
    if ia >= 0 and ib > ia:
        return [[p[0], p[1]] for p in geo[ia:ib + 1]]
    return None


# ---------- build：走廊排序链式拼接 ----------


def _point_seg_dist(p, a, b):
    """点到线段距离与段内参数。"""
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    if l2 <= 0:
        return math.hypot(px - ax, py - ay), 0.0
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy), t


class Corridor:
    """旧线形走廊：投影返回 (距离, 归一化弧长参数 t)。"""

    def __init__(self, pts):
        self.pts = pts
        cum = [0.0]
        for a, b in zip(pts, pts[1:]):
            cum.append(cum[-1] + dist_m(a, b))
        self.cum = cum
        self.total = cum[-1] if cum else 0.0

    def project(self, p):
        best_d, best_t = 1e18, 0.0
        for i in range(len(self.pts) - 1):
            d, t = _point_seg_dist(p, self.pts[i], self.pts[i + 1])
            if d < best_d:
                seg_len = self.cum[i + 1] - self.cum[i]
                best_d = d
                best_t = (self.cum[i] + seg_len * t) / max(self.total, 1.0)
        return best_d, best_t


def _is_hs_way(tags):
    n = str(tags.get("name", "") or "")
    return (tags.get("highspeed") == "yes"
            or "高铁" in n or "高速铁路" in n or "高速线" in n
            or "客运专线" in n)


def dp_simplify(pts, tol):
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


def poly_len(pts):
    return sum(dist_m(a, b) for a, b in zip(pts, pts[1:]))


def cmd_build(line_id):
    docs = read_stdin_docs()
    if len(docs) < 2:
        die("[build] stdin 需要线路 JSON + 至少一份 OSM 文档")
    line, osm = docs[0], {"elements": []}
    for d in docs[1:]:
        osm["elements"].extend(d.get("elements", []))
    stations = line["stations"]
    n_pairs = len(stations) - 1
    if len(stations) < 2 or len(line.get("geometry", [])) < 2:
        die("[build] %s 线路数据不足" % line_id)

    # 按线路等级过滤 way 子图（匿名 way 保留——部分区段高铁未命名）
    # 例外：自动发现的列车走线（自动线 B*）物理上跨普速/高速干线运行
    # （如 杨陵南—武功 经 陇海线 进西安站），等级名过滤会砍掉必经轨道，
    # 导致 A* 拼接与族链双双失败——此类线路用全量轨道图。
    _auto_route = str(line.get("name", "")).startswith("自动线")
    _cls = str(line.get("line_class", ""))
    if _auto_route:
        pass
    elif _cls in ("hsr350", "hsr250", "intercity"):
        osm["elements"] = [e for e in osm["elements"]
                           if e.get("type") != "way"
                           or not str((e.get("tags") or {}).get("name", "") or "")
                           or _is_hs_way(e.get("tags") or {})]
    elif _cls in ("conventional", "freight"):
        osm["elements"] = [e for e in osm["elements"]
                           if e.get("type") != "way"
                           or not str((e.get("tags") or {}).get("name", "") or "")
                           or not _is_hs_way(e.get("tags") or {})]

    # 碎片收集：中点距走廊 ≤12km，按首节点去重（重叠缓存重复抓取同一 way）
    corridor = Corridor([(float(p[0]), float(p[1])) for p in line["geometry"]])
    frags = {}
    for el in osm.get("elements", []):
        if el.get("type") != "way":
            continue
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue
        coords = [(float(p["lon"]), float(p["lat"])) for p in geom]
        name = str((el.get("tags") or {}).get("name", "") or "")
        # 站场净化：匿名短碎片（<1.5km 的站场/渡线轨道）不入链，
        # 避免大站周围的面条环线；匿名长正线（如辽宁段高铁）保留
        if name == "" and poly_len(coords) < 1500.0:
            continue
        mid = coords[len(coords) // 2]
        d, t = corridor.project(mid)
        if d > CORRIDOR_MAX_M:
            continue
        frags.setdefault(el["nodes"][0],
                         {"name": name, "pts": coords, "t": t})
    if not frags:
        die("[build] %s 走廊内无 OSM 碎片" % line_id)
    frs = sorted(frags.values(), key=lambda f: f["t"])

    # 全量碎片（不过走廊）：同名家族即线路身份，山区旧走廊偏差大时
    # 走廊过滤会错杀真实走向——主名族链配合站点覆盖校验兜底
    frags_all = {}
    for el in osm.get("elements", []):
        if el.get("type") != "way":
            continue
        geom = el.get("geometry") or []
        if len(geom) < 2:
            continue
        coords = [(float(p["lon"]), float(p["lat"])) for p in geom]
        name = str((el.get("tags") or {}).get("name", "") or "")
        if name == "" and poly_len(coords) < 1500.0:
            continue
        frags_all.setdefault(el["nodes"][0],
                             {"name": name, "pts": coords, "t": 0.0})

    # 碎片链接：优先「主导名」碎片族（同名 way 属同一物理铁路，
    # 独立描段后沿走廊排序即可无缝成链）；校验失败再试次选名称
    import collections
    name_counts = collections.Counter(f["name"] for f in frs if f["name"])
    candidates = [n for n, _ in name_counts.most_common(3)]

    def chain_family_free(name):
        """同名碎片全量族：走廊投影作前进门控（碎片可偏离走廊，
        沿走廊方向的投影仍单调——双线/折返被门控挡住）。"""
        fam = [f for f in frags_all.values() if f["name"] == name]
        if len(fam) < 2:
            return None
        for f in fam:
            f["ta"] = corridor.project(f["pts"][0])[1]
            f["tb"] = corridor.project(f["pts"][-1])[1]
        fam.sort(key=lambda f: min(f["ta"], f["tb"]))
        used = set()
        out_f = []
        last_t = -1.0
        n_gap = 0
        progress = True
        while progress:
            progress = False
            cand = None
            # 双线铁路每方向一条 way：平行碎片（起点已在已拼范围内）会把
            # 第二轨整段拼进链里导致长度 ×2——优先「向前」碎片，平行碎片
            # 仅当无向前候选时兜底
            for pass_only_forward in (True, False):
                for i, f in enumerate(fam):
                    if i in used:
                        continue
                    lo, hi = min(f["ta"], f["tb"]), max(f["ta"], f["tb"])
                    if hi < last_t - 0.01 or lo > last_t + 0.05:
                        continue
                    if pass_only_forward and lo < last_t - 0.02:
                        continue  # 平行/回退碎片：本轮跳过
                    if f["ta"] <= f["tb"]:
                        entry, far = f["pts"][0], f["pts"][-1]
                        t_far = f["tb"]
                    else:
                        entry, far = f["pts"][-1], f["pts"][0]
                        t_far = f["ta"]
                    if t_far < last_t - 0.01:
                        continue
                    dcur = dist_m(out_f[-1], entry) if out_f else 0.0
                    if cand is None or dcur < cand[0]:
                        cand = (dcur, i, entry, far, t_far)
                if cand is not None:
                    break
            if cand is not None:
                _d, i, entry, far, t_far = cand
                f = fam[i]
                seg = f["pts"] if f["pts"][0] == entry else f["pts"][::-1]
                if out_f and dist_m(out_f[-1], seg[0]) < 50.0:
                    seg = seg[1:]
                elif out_f:
                    n_gap += 1
                out_f.extend(seg)
                last_t = max(last_t, t_far)
                used.add(i)
                progress = True
                continue
            jump = None
            for i, f in enumerate(fam):
                if i in used:
                    continue
                lo = min(f["ta"], f["tb"])
                if lo <= last_t - 0.01:
                    continue
                if jump is None or lo < jump[0]:
                    jump = (lo, i)
            if jump is not None:
                i = jump[1]
                f = fam[i]
                seg = f["pts"] if f["ta"] <= f["tb"] else f["pts"][::-1]
                if out_f and dist_m(out_f[-1], seg[0]) < 50.0:
                    seg = seg[1:]
                elif out_f:
                    n_gap += 1
                out_f.extend(seg)
                last_t = max(last_t, max(f["ta"], f["tb"]))
                used.add(i)
                progress = True
        span = max(max(f["ta"], f["tb"]) for f in fam) - \
            min(min(f["ta"], f["tb"]) for f in fam)
        return out_f, n_gap, span

    def station_coverage_ok(pts_f, max_m=30000.0):
        for s in stations:
            pos = (float(s["lon"]), float(s["lat"]))
            dmin = 1e18
            for p in pts_f:
                d = dist_m(pos, p)
                if d < dmin:
                    dmin = d
            if dmin > max_m:
                return False
        return True

    def chain_family(name):
        fam = [f for f in frs if f["name"] == name]
        if len(fam) < 2:
            return None
        s0 = (float(stations[0]["lon"]), float(stations[0]["lat"]))
        # 预计算每碎片两端点的走廊投影（前进门控用）
        for f in fam:
            f["p0"] = corridor.project(f["pts"][0])[1]
            f["p1"] = corridor.project(f["pts"][-1])[1]
        used = set()
        best = None
        for i, f in enumerate(fam):
            for endi, p in ((0, f["pts"][0]), (1, f["pts"][-1])):
                d = dist_m(s0, p)
                if best is None or d < best[0]:
                    best = (d, i, endi)
        _d, i0, endi0 = best
        start_f = fam[i0]
        out_f = list(start_f["pts"] if endi0 == 0 else start_f["pts"][::-1])
        used.add(i0)
        cur_proj = start_f["p1"] if endi0 == 0 else start_f["p0"]
        n_gap = 0
        while True:
            cur_end = out_f[-1]
            # 1) 同点延续（≤50m）且方向向前：取投影最远的一条穿过站场
            cont = None
            for i, f in enumerate(fam):
                if i in used:
                    continue
                d0 = dist_m(cur_end, f["pts"][0])
                d1 = dist_m(cur_end, f["pts"][-1])
                if min(d0, d1) < 50.0:
                    far = f["p1"] if d0 <= d1 else f["p0"]
                    if far < cur_proj - 0.005:
                        continue  # 折返碎片跳过
                    if cont is None or far > cont[3]:
                        cont = (i, d0, d1, far)
            if cont is not None:
                i, d0, d1, far = cont
                seg = fam[i]["pts"][::-1] if d1 < d0 else fam[i]["pts"]
                used.add(i)
                if dist_m(out_f[-1], seg[0]) < 1.0:
                    seg = seg[1:]
                out_f.extend(seg)
                cur_proj = far
                continue
            # 2) 最近端点（≤CHAIN_GAP）且向前
            best = None
            for i, f in enumerate(fam):
                if i in used:
                    continue
                d0 = dist_m(cur_end, f["pts"][0])
                d1 = dist_m(cur_end, f["pts"][-1])
                d = min(d0, d1)
                far = f["p1"] if d0 <= d1 else f["p0"]
                if far < cur_proj - 0.005:
                    continue
                if best is None or d < best[0]:
                    best = (d, i, d0, d1, far)
            if best is None or best[0] > CHAIN_GAP_M:
                # 断口跳接：跳到投影最靠前的未用碎片（OSM 数据缺口直连）
                jump = None
                for i, f in enumerate(fam):
                    if i in used:
                        continue
                    mn = min(f["p0"], f["p1"])
                    if mn < cur_proj - 0.005:
                        continue
                    if jump is None or mn < jump[0]:
                        jump = (mn, i)
                if jump is None:
                    break
                _mn, i = jump
                f = fam[i]
                d0 = dist_m(cur_end, f["pts"][0])
                d1 = dist_m(cur_end, f["pts"][-1])
                seg = f["pts"][::-1] if d1 < d0 else f["pts"]
                used.add(i)
                n_gap += 1
                out_f.extend(seg)
                cur_proj = max(cur_proj, max(f["p0"], f["p1"]))
                continue
            _d, i, d0, d1, far = best
            seg = fam[i]["pts"][::-1] if d1 < d0 else fam[i]["pts"]
            used.add(i)
            if best[0] > 1.0:
                n_gap += 1
            if dist_m(out_f[-1], seg[0]) < 1.0:
                seg = seg[1:]
            out_f.extend(seg)
            cur_proj = far
        return out_f, n_gap, 1.0

    old_len = poly_len([(p[0], p[1]) for p in line.get("geometry", [])])
    chosen = None

    # 第一级：逐对 A*（缝合图最短路只走一条轨，天然无双线加倍）
    g = RailGraph(osm) if osm.get("elements") else None
    if g is not None and g.nodes:
        snap = {}
        coord_fixed = 0
        for s in stations:
            pt = (float(s["lon"]), float(s["lat"]))
            cands = g.nearest_nodes(pt)
            if cands:
                nid, d = cands[0]
                snap[s["id"]] = nid
                # 修正距离上限 25km：更远的偏移说明链走错（或原始坐标
                # 本就正确而链偏了），保留原坐标，避免灾难性拖站
                if COORD_FIX_M < d <= 25000.0:
                    s["lon"], s["lat"] = g.nodes[nid]
                    coord_fixed += 1
            else:
                snap[s["id"]] = None
        if coord_fixed:
            eprint("[build] %s: 修正 %d 站坐标（吸附至 OSM 真实位置）"
                   % (line_id, coord_fixed))
        geometry_pair = []
        ok_pairs = fb_pairs = 0
        for k in range(n_pairs):
            sa, sb = stations[k], stations[k + 1]
            pa = (float(sa["lon"]), float(sa["lat"]))
            pb = (float(sb["lon"]), float(sb["lat"]))
            base = max(gc_m(pa, pb), 500.0)
            seg = None
            na, nb = snap.get(sa["id"]), snap.get(sb["id"])
            if na is not None and nb is not None and g.comp_of(na) == g.comp_of(nb):
                node_path = astar_path(g, na, nb)
                if node_path:
                    seg = [pa] + [g.nodes[n] for n in node_path] + [pb]
                    if gc_m(pa, pb) > 1.0 and poly_len(seg) / base > 2.6:
                        seg = None
            if seg is None:
                fb_pairs += 1
                old = old_segment(line, sa["id"], sb["id"])
                seg = old if old else [[pa[0], pa[1]], [pb[0], pb[1]]]
            else:
                ok_pairs += 1
            if geometry_pair and dist_m(geometry_pair[-1], seg[0]) < 1.0:
                seg = seg[1:]
            geometry_pair.extend(seg)
        pair_len = poly_len(geometry_pair)
        pair_ratio = pair_len / max(old_len, 1.0)
        fb_frac = fb_pairs / max(n_pairs, 1)
        if LEN_RATIO_MIN <= pair_ratio <= LEN_RATIO_MAX and fb_frac <= 0.45:
            eprint("[build] %s: 逐对 A*（OK %d / 回退 %d）x%.2f => 采纳"
                   % (line_id, ok_pairs, fb_pairs, pair_ratio))
            chosen = (geometry_pair, fb_pairs, "逐对A*")

    # 第二级：全量主名族（无走廊限制，山区友好）
    if chosen is None:
        import collections as _collections
        all_counts = _collections.Counter(
            f["name"] for f in frags_all.values() if f["name"])
        # 名称变体优先：数据名常为「xx铁路」，OSM 官方名多为「xx高速线/线」
        name_variants = [str(line.get("name", ""))]
        if name_variants[0].endswith("铁路"):
            base = name_variants[0][:-2]
            name_variants.append(base + ("线" if "高速" in base else "高速线"))
            name_variants.append(base + "线")
        variant_set = set(name_variants)
        ordered = name_variants + [n for n, _ in all_counts.most_common(6)
                                   if n not in variant_set]
        for name in ordered:
            r = chain_family_free(name)
            if not r:
                if os.environ.get("DIAG"):
                    eprint("[diag] %s 族「%s」: 碎片<2 或链为空" % (line_id, name))
                continue
            pts_f, n_gap_f, span_f = r
            if len(pts_f) < 2 or span_f < 0.80:
                if os.environ.get("DIAG"):
                    eprint("[diag] %s 族「%s」: span=%.2f pts=%d" %
                           (line_id, name, span_f, len(pts_f)))
                continue
            # 截取到站序范围：家族链可能延伸出数据区段（如 宁杭全程 vs
            # 数据部分段、京哈家族 vs 哈大段）——先截取再验长度比
            s0 = (float(stations[0]["lon"]), float(stations[0]["lat"]))
            sN = (float(stations[-1]["lon"]), float(stations[-1]["lat"]))
            i0 = min(range(len(pts_f)), key=lambda k: dist_m(s0, pts_f[k]))
            iN = min(range(len(pts_f)), key=lambda k: dist_m(sN, pts_f[k]))
            if i0 > iN:
                pts_f = pts_f[::-1]
                i0, iN = len(pts_f) - 1 - i0, len(pts_f) - 1 - iN
            if iN - i0 >= max(4, len(pts_f) // 8):
                pts_f = pts_f[i0:iN + 1]
            len_f = poly_len(pts_f)
            if not (0.65 <= len_f / max(old_len, 1.0) <= 1.9):
                if os.environ.get("DIAG"):
                    eprint("[diag] %s 族「%s」: 截取后比值 x%.2f (%.0f/%.0f km)" %
                           (line_id, name, len_f / max(old_len, 1.0),
                            len_f / 1000.0, old_len / 1000.0))
                continue
            if not station_coverage_ok(pts_f):
                if os.environ.get("DIAG"):
                    eprint("[diag] %s 族「%s」: 站点覆盖不足" % (line_id, name))
                continue
            chosen = (pts_f, n_gap_f, name)
            break

    # 第三级：走廊族（原有路径）
    if chosen is None:
        for name in candidates:
            r = chain_family(name)
            if not r:
                continue
            pts_f, n_gap_f, span_f = r
            if len(pts_f) < 2 or span_f < 0.80:
                continue
            len_f = poly_len(pts_f)
            if not (LEN_RATIO_MIN <= len_f / max(old_len, 1.0) <= LEN_RATIO_MAX):
                continue
            chosen = (pts_f, n_gap_f, name)
            break
    if chosen is None:
        eprint("[build] %s: 无可用同名碎片族 => KEEP-OLD" % line_id)
        json.dump(line, sys.stdout, ensure_ascii=False, indent=2)
        return
    out, n_gap, fam_name = chosen
    eprint("[build] %s: 主名碎片族「%s」" % (line_id, fam_name))
    if len(out) < 2:
        die("[build] %s 链接结果过短" % line_id)

    # 站序单调向前吸附到链上最近顶点；偏差 >2km 修正站坐标。
    # tagged 集合保证每站独占一个顶点——两站同顶点会覆盖标记，
    # 导致 geometry 丢站标签、运行时 station_arc 缺失
    geometry = [[p[0], p[1], None] for p in out]
    coord_fixed = 0
    tagged = set()
    prev_idx = 0
    for s in stations:
        pos = (float(s["lon"]), float(s["lat"]))
        if prev_idx >= len(out) - 1:
            # 链已耗尽：把剩余站点追加为线的延伸顶点（标记不丢失）
            out.append(pos)
            geometry.append([pos[0], pos[1], s["id"]])
            tagged.add(len(geometry) - 1)
            prev_idx = len(out) - 1
            continue
        best_i, best_d = prev_idx, 1e18
        for i in range(prev_idx, len(out)):
            d = dist_m(pos, out[i])
            if d < best_d:
                best_d, best_i = d, i
        if best_i <= prev_idx:
            best_i = min(prev_idx + 1, len(out) - 1)
        while best_i in tagged and best_i < len(out) - 1:
            best_i += 1
        if best_i in tagged:
            # 顶点被占且无法前进：追加新顶点
            out.append(pos)
            geometry.append([pos[0], pos[1], s["id"]])
            tagged.add(len(geometry) - 1)
            prev_idx = len(out) - 1
            continue
        tagged.add(best_i)
        if COORD_FIX_M < best_d <= 25000.0:
            s["lon"], s["lat"] = out[best_i]
            coord_fixed += 1
        geometry[best_i] = [s["lon"], s["lat"], s["id"]]
        prev_idx = best_i
    if coord_fixed:
        eprint("[build] %s: 修正 %d 站坐标（吸附至 OSM 真实位置）"
               % (line_id, coord_fixed))

    # 区段独立简化（保住车站标记）
    simplified = []
    start = 0
    for i in range(1, len(geometry)):
        if len(geometry[i]) > 2 and geometry[i][2]:
            simp = dp_simplify(geometry[start:i + 1], SIMPLIFY_TOL_M)
            if simplified and dist_m(tuple(simplified[-1][:2]), tuple(simp[0])) < 1.0:
                simp = simp[1:]
            simplified.extend(simp)
            start = i

    # 整线校验
    new_len = poly_len([(p[0], p[1]) for p in simplified])
    old_len = poly_len([(p[0], p[1]) for p in line.get("geometry", [])])
    ratio = new_len / max(old_len, 1.0)
    fam_name = locals().get("fam_name", "?")
    ok = LEN_RATIO_MIN <= ratio <= LEN_RATIO_MAX
    eprint("[build] %s: 碎片族「%s」（缺口直连 %d）旧长 %.0f km 新长 %.0f km "
           "(x%.2f) 顶点 %d -> %d => %s"
           % (line_id, fam_name, n_gap, old_len / 1000, new_len / 1000,
              ratio, len(out), len(simplified), "OK" if ok else "KEEP-OLD"))
    if not ok:
        json.dump(line, sys.stdout, ensure_ascii=False, indent=2)
        return

    out_doc = dict(line)
    out_doc["geometry"] = simplified
    note = str(line.get("note", ""))
    if "OSM 真实线形" not in note:
        out_doc["note"] = (note + " | 线形为 OSM 真实铁路走向（Overpass）。").strip(" |")
    json.dump(out_doc, sys.stdout, ensure_ascii=False, indent=2)


def main():
    if len(sys.argv) < 3:
        die("用法: osm_geometry.py fetch <line_id> [pair|s<站序>] < line.json\n"
            "      osm_geometry.py build <line_id> < (line.json + osm*.json)")
    cmd = sys.argv[1]
    line_id = check_line_id(sys.argv[2])
    pair = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else None
    st_idx = int(sys.argv[3][1:]) if len(sys.argv) > 3 and sys.argv[3].startswith("s") \
        and sys.argv[3][1:].isdigit() else None
    if cmd == "fetch":
        cmd_fetch(line_id, pair, st_idx)
    elif cmd == "build":
        cmd_build(line_id)
    else:
        die("未知子命令: %s" % cmd)


if __name__ == "__main__":
    main()

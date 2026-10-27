# -*- coding: utf-8 -*-
"""批量用 OSM 真实铁路线形替换线路近似线形（Overpass API）。

本工具自身零文件 I/O：线路文档与 OSM 缓存均从 stdin 读入，
结果只写 stdout，文件持久化全部由 bash 重定向完成。

子命令：
  fetch <line_id>   stdin= 线路 JSON；向 Overpass 抓该线包围盒内
                    railway=rail way，JSON 打到 stdout
  build <line_id>   stdin= 线路 JSON 与 OSM 缓存 JSON 顺序拼接
                    （依次 raw_decode 两份文档）；输出整份线路 JSON

流程（build）：
  1. OSM way 按共享节点做并查集 -> 连通分量（不同铁路基本不共节点，
     天然防止把走线拼到平行线上）；
  2. 每座车站吸附到分量内最近节点（空间网格加速）；
  3. 相邻站对：在共同分量上跑 A*（大圆距离启发式）得到真实走线；
  4. 绕路比 > MAX_DETOUR 的站对回退为旧线形对应区段（找不到则直线）；
  5. 区段独立 Douglas-Peucker 简化（保住车站标记点），整线长度比校验，
     回退站对比例过高则整线放弃（原样输出旧文档），保留旧线形。

安全约定：Overpass 仅允许白名单域名的 https 端点，请求前解析 DNS
并阻断私网/环回/链路本地地址；line_id 仅用于日志（仍做格式校验）。
"""
import heapq
import json
import math
import re
import socket
import sys
import time
import urllib.parse
import urllib.request

import timetable_lib as lib

BBOX_PAD = 0.22          # 线路包围格外扩（度）
SNAP_MAX_M = 5000.0      # 车站吸附分量最近节点的最大距离
MAX_DETOUR = 2.6         # 站对走线长 / 大圆距离 的上限
SIMPLIFY_TOL_M = 120.0   # DP 简化容差
LEN_RATIO_MIN, LEN_RATIO_MAX = 0.55, 1.9   # 新旧整线长度比的安全区间
MAX_FALLBACK_FRAC = 0.45  # 回退站对比例上限（超过则整线放弃）

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
]
ALLOWED_HOSTS = {"overpass-api.de", "overpass.osm.ch"}
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


def read_stdin_docs(n=2):
    """从 stdin 顺序 raw_decode n 份 JSON 文档。"""
    text = sys.stdin.read()
    dec = json.JSONDecoder()
    pos = 0
    docs = []
    for _ in range(n):
        while pos < len(text) and text[pos] in " \t\r\n":
            pos += 1
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


def cmd_fetch(line_id, pair_idx=None):
    (line,) = read_stdin_docs(1)
    sts = line["stations"]
    if pair_idx is None:
        sel = sts
    else:
        if not (0 <= pair_idx < len(sts) - 1):
            die("pair 越界: %s k=%d" % (line_id, pair_idx))
        sel = [sts[pair_idx], sts[pair_idx + 1]]
    lons = [float(s["lon"]) for s in sel]
    lats = [float(s["lat"]) for s in sel]
    south, north = min(lats) - BBOX_PAD, max(lats) + BBOX_PAD
    west, east = min(lons) - BBOX_PAD, max(lons) + BBOX_PAD
    query = ("[out:json][timeout:120];"
             'way["railway"="rail"](%f,%f,%f,%f);out geom qt;'
             % (south, west, north, east))
    last_err = None
    for rnd in range(2):  # 快速失败：整体重跑兜底，不在单任务里久耗
        try:
            doc, n_way, nbytes, url = overpass_post(query)
            eprint("[fetch] %s[%s]: %d ways, %.1f MB, (%s)"
                   % (line_id, "?" if pair_idx is None else pair_idx,
                      n_way, nbytes / 1e6, url))
            json.dump(doc, sys.stdout, ensure_ascii=False)
            return
        except Exception as exc:
            last_err = exc
            time.sleep(6 + 8 * rnd)
    die("[fetch] %s 全部端点失败: %s" % (line_id, last_err))


# ---------- build：图构建与走线 ----------


class RailGraph:
    """OSM way 集合 -> 连通分量（并查集）+ 邻接表 + 节点空间网格。"""

    def __init__(self, doc):
        ways = []
        for el in doc.get("elements", []):
            if el.get("type") != "way":
                continue
            node_ids = el.get("nodes") or []
            geom = el.get("geometry") or []
            if len(node_ids) >= 2 and len(geom) >= 2 and len(node_ids) == len(geom):
                ways.append((node_ids, [(float(p["lon"]), float(p["lat"]))
                                        for p in geom]))
        self.parent = {}

        def find(x):
            root = x
            while self.parent[root] != root:
                root = self.parent[root]
            while self.parent[x] != root:
                self.parent[x], x = root, self.parent[x]
            return root
        self._find = find

        def union(a, b):
            for v in (a, b):
                self.parent.setdefault(v, v)
            ra, rb = find(a), find(b)
            if ra != rb:
                self.parent[ra] = rb

        self.nodes = {}
        for nids, coords in ways:
            for nid, c in zip(nids, coords):
                self.nodes[nid] = c
            for a, b in zip(nids, nids[1:]):
                union(a, b)
        self.adj = {}
        for nids, coords in ways:
            for (a, ca), (b, cb) in zip(zip(nids, coords), zip(nids[1:], coords[1:])):
                if find(a) != find(b):
                    continue
                w = dist_m(ca, cb)
                if w <= 0:
                    continue
                self.adj.setdefault(a, []).append((b, w))
                self.adj.setdefault(b, []).append((a, w))
        self.grid = {}
        cs = 0.01
        for nid, (lon, lat) in self.nodes.items():
            self.grid.setdefault((int(lon / cs), int(lat / cs)), []).append(nid)
        self._cs = cs

    def comp_of(self, nid):
        return self._find(nid)

    def nearest_nodes(self, pt, max_m=SNAP_MAX_M):
        """返回 [(node_id, dist_m)] 按距离升序（网格扩散查找）。"""
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
    """分量内 A*（启发式 = 到终点大圆距离；边权 >= 大圆距离，可采纳）。"""
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
    if n_pairs < 1:
        die("[build] %s 车站不足" % line_id)

    g = RailGraph(osm)
    if not g.nodes:
        die("[build] %s OSM 数据为空" % line_id)

    # 每站最近节点候选（跨分量）
    snap = {}
    for s in stations:
        pt = (float(s["lon"]), float(s["lat"]))
        snap[s["id"]] = g.nearest_nodes(pt)

    geometry = []
    n_ok = n_fb = 0
    for k in range(n_pairs):
        sa, sb = stations[k], stations[k + 1]
        pa = (float(sa["lon"]), float(sa["lat"]))
        pb = (float(sb["lon"]), float(sb["lat"]))
        base_len = max(gc_m(pa, pb), 500.0)
        # 共同分量中选 dA+dB 最小的节点对
        best = None
        for na, da in snap[sa["id"]]:
            ca = g.comp_of(na)
            for nb, db in snap[sb["id"]]:
                if ca == g.comp_of(nb) and (best is None or da + db < best[0]):
                    best = (da + db, na, nb)
        seg = None
        if best is not None:
            _, na, nb = best
            node_path = astar_path(g, na, nb)
            if node_path:
                if gc_m(pa, pb) < 1.0:
                    seg = [g.nodes[na], g.nodes[nb]]
                else:
                    seg = [pa] + [g.nodes[n] for n in node_path] + [pb]
                    if poly_len(seg) / base_len > MAX_DETOUR:
                        seg = None
        if seg is None:
            n_fb += 1
            old = old_segment(line, sa["id"], sb["id"])
            seg = old if old else [[pa[0], pa[1]], [pb[0], pb[1]]]
            if not old:
                eprint("[build] %s: %s-%s 无旧线形，用直线" % (line_id, sa["id"], sb["id"]))
        else:
            n_ok += 1
        # 拼接（去掉与上一段重复的连接点）
        if geometry and dist_m(tuple(geometry[-1][:2]), tuple(seg[0])) < 1.0:
            seg = seg[1:]
        seg = [[p[0], p[1], None] for p in seg]
        if not geometry:
            seg[0][2] = sa["id"]
        seg[-1][2] = sb["id"]
        geometry.extend(seg)

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
    fb_frac = n_fb / max(n_pairs, 1)
    ok = (LEN_RATIO_MIN <= ratio <= LEN_RATIO_MAX) and fb_frac <= MAX_FALLBACK_FRAC
    eprint("[build] %s: 站对 %d（OSM %d / 回退 %d）旧长 %.0f km 新长 %.0f km "
           "(x%.2f) 顶点 %d -> %d => %s"
           % (line_id, n_pairs, n_ok, n_fb, old_len / 1000, new_len / 1000,
              ratio, len(geometry), len(simplified), "OK" if ok else "KEEP-OLD"))
    if not ok:
        json.dump(line, sys.stdout, ensure_ascii=False, indent=2)
        return

    out = dict(line)
    out["geometry"] = simplified
    note = str(line.get("note", ""))
    if "OSM 真实线形" not in note:
        out["note"] = (note + " | 线形为 OSM 真实铁路走向（Overpass）。").strip(" |")
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)


def main():
    if len(sys.argv) < 3:
        die("用法: osm_geometry.py fetch <line_id> [pair] < line.json\n"
            "      osm_geometry.py build <line_id> < (line.json + osm*.json)")
    cmd = sys.argv[1]
    line_id = check_line_id(sys.argv[2])
    pair = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else None
    if cmd == "fetch":
        cmd_fetch(line_id, pair)
    elif cmd == "build":
        cmd_build(line_id)
    else:
        die("未知子命令: %s" % cmd)


if __name__ == "__main__":
    main()

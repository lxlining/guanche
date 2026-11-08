# 地图渲染：经纬网、海岸线、河流湖泊、省市标注、线路与车站。
# 全部世界坐标自绘（custom _draw），字号/线宽按相机缩放换算保持屏幕像素恒定。
extends Node2D

const GeoScript := preload("res://src/core/geo.gd")

const COL_LINE_BASE := Color("151b28")
const COL_LINE_CORE := Color("6272e0")
const COL_STATION_FILL := Color("0d1117")
const COL_STATION_RING := Color("e8ecf5")
const COL_TEXT := Color("dbe2ee")
const COL_TEXT_DIM := Color(0.72, 0.77, 0.86, 0.85)
const COL_WATER := Color(0.22, 0.34, 0.48, 0.55)
const COL_GRATICULE := Color(1, 1, 1, 0.045)

var _stars: Array = []  # 懒生成：{pos, size, phase, spd}
var _lod_cache := {}   # "line_id|缩放桶" -> 贪心抽稀折线（保留点间距≥3.5px）
var _seg_cache := {}   # "line_id|缩放桶" -> 线段对数组（重绘仅重放，不重建）
# 保留式路网：缩放桶/可见性变化时一次性记录到 RenderingServer canvas item，
# 平移与静止帧零重录（此前逐帧重录 6 万线段是近景 1-2fps 的主因）。
var _line_host: Node2D
var _rs_items: Array = []      # RID 列表
var _rs_bucket := -999999
var _rs_sig := ""
var _geo_host: Node2D
var _geo_items: Array = []     # 省界/海岸/河流保留式 item
var _geo_bucket := -999999
var _geo_sig := ""


func _ready() -> void:
	_line_host = Node2D.new()
	_line_host.name = "RSLineHost"
	add_child(_line_host)
	_geo_host = Node2D.new()
	_geo_host.name = "RSGeoHost"
	add_child(_geo_host)
	_precalc_deserts()


func _exit_tree() -> void:
	for rid in _rs_items:
		RenderingServer.free_rid(rid)
	for rid in _geo_items:
		RenderingServer.free_rid(rid)
	_rs_items = []
	_geo_items = []
var _last_cam := Vector2(NAN, NAN)
var _last_zoom := -1.0
var _idle_accum := 0.0


func _process(delta: float) -> void:
	# 全图几何量大（251 线 OSM 折线 + 2348 站 + 地理装饰），重绘是最大开销：
	# 相机移动才逐帧重绘（视口变换不触发 Item 重绘，必须显式刷）；静止时
	# 仅 1Hz 低温重绘维持星空闪烁与天色渐变。
	var cam := get_viewport().get_camera_2d()
	var cp := cam.get_screen_center_position() if cam != null else Vector2.ZERO
	var cz := cam.zoom.x if cam != null else 1.0
	if not is_equal_approx(cp.x, _last_cam.x) or not is_equal_approx(cp.y, _last_cam.y) \
			or not is_equal_approx(cz, _last_zoom):
		_last_cam = cp
		_last_zoom = cz
		_idle_accum = 0.0
		queue_redraw()
		return
	_idle_accum += delta
	if _idle_accum >= 1.0:
		_idle_accum = 0.0
		queue_redraw()
	# 保留式路网：缩放桶/可见性签名变更才重录；天色亮度经宿主 modulate 调制
	var bucket := 0
	if cz > 0.0:
		bucket = int(round(log(maxf(cz, 1.0e-5)) / log(2.0)))
	var sig := str(Meta.focus_line) + "|" + str(Meta.class_visible) + "|" + str(DB.line_order.size())
	if bucket != _rs_bucket or sig != _rs_sig:
		_rs_bucket = bucket
		_rs_sig = sig
		_rebuild_rs_lines(cz)
	if bucket != _geo_bucket or sig != _geo_sig:
		_geo_bucket = bucket
		_geo_sig = sig
		_rebuild_rs_geo(cz)
	var dfk := 0.55 + 0.45 * daylight_factor(GameTime.t)
	_line_host.modulate = Color(dfk, dfk, dfk, 1.0)
	_geo_host.modulate = Color(dfk, dfk, dfk, 1.0)




# 省界/海岸/河流：保留式记录（数据静态，桶变更才重录）
func _rebuild_rs_geo(zoom: float) -> void:
	for rid in _geo_items:
		RenderingServer.free_rid(rid)
	_geo_items = []
	var zb := pow(2.0, float(_geo_bucket))
	var px0 := 1.0 / maxf(zb, 1.0e-6)
	var bg := DB.background
	var ci := RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(ci, _geo_host.get_canvas_item())
	# 省界：淡填充 + 细边线
	for prov in bg.get("provinces", []):
		for wpts in prov["polys"]:
			if wpts.size() < 3:
				continue
			var cols := PackedColorArray([Color(0.10, 0.14, 0.21, 0.55)])
			RenderingServer.canvas_item_add_polygon(ci, wpts, cols)
			var outline: PackedVector2Array = wpts.duplicate()
			outline.push_back(wpts[0])
			RenderingServer.canvas_item_add_polyline(ci, outline,
					PackedColorArray([Color(0.32, 0.40, 0.52, 0.8)]),
					1.1 * maxf(px0, 1.0), false)
	# 海岸线
	for coast in bg.get("wcoastlines", []):
		RenderingServer.canvas_item_add_polyline(ci, coast,
				PackedColorArray([Color(0.45, 0.58, 0.72, 0.5)]), 1.5 * px0, false)
	# 河流
	for river in bg.get("rivers", []):
		RenderingServer.canvas_item_add_polyline(ci, river["wpts"],
				PackedColorArray([COL_WATER]), 3.5 * px0, false)
	_geo_items.append(ci)


# 天色因子：0=深夜 1=正午；根据游戏时刻计算
static func daylight_factor(t: float) -> float:
	var h := t / 3600.0  # 小时 0-24
	if h >= 7.0 and h <= 17.0:
		return 1.0
	if h > 17.0 and h < 20.0:
		return 1.0 - (h - 17.0) / 3.0  # 黄昏渐暗
	if h >= 5.0 and h < 7.0:
		return (h - 5.0) / 2.0  # 黎明渐亮
	return 0.0


func _sky_color(df: float) -> Color:
	# 深夜 → 黎明 → 正午 → 黄昏
	var night := Color(0.028, 0.036, 0.055)
	var dawn := Color(0.10, 0.08, 0.10)
	var noon := Color(0.075, 0.095, 0.135)
	var dusk := Color(0.09, 0.065, 0.075)
	if df >= 0.95:
		return noon
	if df >= 0.5:
		return dawn.lerp(noon, (df - 0.5) / 0.45)
	if df >= 0.15:
		return dawn
	return night.lerp(dawn, df / 0.15)


func _dim_color(c: Color, df: float) -> Color:
	# 线路/标注亮度随天色衰减（夜间暗淡但仍可见）
	var k := 0.55 + 0.45 * df
	return Color(c.r * k, c.g * k, c.b * k, c.a)


func _draw() -> void:
	var dt0 := Time.get_ticks_usec()
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	var px := 1.0 / zoom
	var df := daylight_factor(GameTime.t)
	var wf: float = clampf(zoom / 0.01, 0.55, 1.0)
	# 天空背景
	var sky := _sky_color(df)
	draw_rect(Rect2(Vector2(-2e6, -2e6), Vector2(6e6, 6e6)), sky)
	_draw_stars(px, df)
	var t1 := Time.get_ticks_usec()
	_draw_graticule(px)
	var t2 := Time.get_ticks_usec()
	_draw_geography(px, df)
	var t3 := Time.get_ticks_usec()
	_draw_geo_terrain(px, df)
	var t4 := Time.get_ticks_usec()
	PerfProbe.lap("m_sky", t1 - dt0)
	PerfProbe.lap("m_grat", t2 - t1)
	PerfProbe.lap("m_geo", t3 - t2)
	PerfProbe.lap("m_terr", t4 - t3)
	var view := Rect2(cam.get_screen_center_position() - Vector2(1.5e6, 1.5e6) / zoom,
			Vector2(3e6, 3e6) / zoom)
	_draw_stations(px, df, view, zoom)


func _precalc_deserts() -> void:
	# 沙漠点纹预计算（固定种子，世界坐标）
	for d in DB.geo_rich.get("deserts", []):
		if not d.has("wpos"):
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(str(d.get("name", "")))
		var dots := []
		for i in range(110):
			var ang := rng.randf_range(0.0, TAU)
			var rr := sqrt(rng.randf_range(0.05, 0.95))
			var off := Vector2(cos(ang) * rr * float(d.get("wrx", 1.0)),
					sin(ang) * rr * float(d.get("wry", 1.0)))
			dots.append(d["wpos"] + off)
		d["dots"] = dots





func _draw_graticule(px: float) -> void:
	# 经纬网合并为两次 draw_multiline（原 71 次 draw_line）
	var segs := PackedVector2Array()
	for lon in range(80, 133):
		segs.push_back(GeoScript.lonlat_to_world(float(lon), 17.5))
		segs.push_back(GeoScript.lonlat_to_world(float(lon), 54.0))
	draw_multiline(segs, COL_GRATICULE, maxf(px, 1.0), false)
	var segs2 := PackedVector2Array()
	for lat in range(18, 54):
		segs2.push_back(GeoScript.lonlat_to_world(79.0, float(lat)))
		segs2.push_back(GeoScript.lonlat_to_world(133.0, float(lat)))
	draw_multiline(segs2, COL_GRATICULE, maxf(px, 1.0), false)


# 夜间星空：世界坐标随机星点，亮度随天色渐入、轻微闪烁
func _draw_stars(px: float, df: float) -> void:
	if df > 0.32:
		return
	if _stars.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.seed = 20260101
		for i in range(260):
			_stars.append({
				"pos": GeoScript.lonlat_to_world(rng.randf_range(78.0, 134.0),
						rng.randf_range(17.0, 54.0)),
				"size": rng.randf_range(0.9, 2.3),
				"phase": rng.randf_range(0.0, TAU),
				"spd": rng.randf_range(0.4, 1.4),
			})
	var k: float = clampf((0.32 - df) / 0.32, 0.0, 1.0)
	var t := GameTime.t
	for s in _stars:
		var tw: float = 0.72 + 0.28 * sin(t * s["spd"] + s["phase"])
		draw_circle(s["pos"], s["size"] * px, Color(1, 1, 1, (0.20 + 0.55 * tw) * k))


func _draw_geography(px: float, df: float) -> void:
	var bg := DB.background
	# 省界/海岸/河流已保留式渲染（RSGeoHost），此处只画湖泊与城市光点
	for lake in bg.get("lakes", []):
		draw_set_transform(lake["wpos"], 0.0, Vector2(lake["wrx"] / lake["wry"], 1.0))
		draw_circle(Vector2.ZERO, lake["wry"], COL_WATER * Color(1, 1, 1, 0.6))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	for pl in bg.get("province_labels", []):
		pass  # 省份标注由 LabelLayer 绘制

	for c in bg.get("cities", []):
		var pos: Vector2 = c["wpos"]
		var major: bool = c.get("major", false)
		# 夜间城市灯火：暖色光晕，白天恢复普通灰白点
		if df < 0.45:
			var lk: float = (0.45 - df) / 0.45
			var glow: float = (7.5 if major else 4.5) * px
			draw_circle(pos, glow, Color(1.0, 0.80, 0.42, 0.10 * lk))
			draw_circle(pos, glow * 0.45, Color(1.0, 0.84, 0.5, 0.28 * lk))
		draw_circle(pos, (3.0 if major else 2.0) * px,
				_dim_color(Color(0.82, 0.87, 0.95, 0.75), 0.35 + 0.65 * df))


const CLASS_WIDTH := {"hsr350": 5.5, "hsr250": 4.5, "intercity": 4.0, "conventional": 2.6, "freight": 3.2}

func _draw_geo_terrain(px: float, df: float) -> void:
	# 地貌区淡色块（高原/盆地/平原）
	var region_tint := Color(0.55, 0.5, 0.38, 0.05 + 0.04 * (1.0 - df))
	for g in DB.geo_rich.get("regions", []):
		if not g.has("wpos"):
			continue
		draw_set_transform(g["wpos"], 0.0, Vector2(g["wrx"], g["wry"]))
		draw_circle(Vector2.ZERO, 1.0, region_tint)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# 沙漠点纹（菱形并入三角批缓冲，单次提交；逐点 draw_circle 数百 call 不可接受）
	var desert_col := _dim_color(Color(0.72, 0.62, 0.38, 0.3), df)
	var d_idx := PackedInt32Array()
	var d_pts := PackedVector2Array()
	var d_cols := PackedColorArray()
	var d_base := 0
	for d in DB.geo_rich.get("deserts", []):
		if not d.has("wpos"):
			continue
		for dot in d.get("dots", []):
			var dp: Vector2 = dot
			var r2 := 3.0 * px
			d_pts.push_back(dp + Vector2(0, -r2))
			d_pts.push_back(dp + Vector2(r2, 0))
			d_pts.push_back(dp + Vector2(0, r2))
			d_pts.push_back(dp + Vector2(-r2, 0))
			d_idx.append_array(PackedInt32Array([d_base, d_base + 1, d_base + 2,
					d_base, d_base + 2, d_base + 3]))
			for _k in range(4):
				d_cols.push_back(desert_col)
			d_base += 4
	if d_base > 0:
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), d_idx, d_pts, d_cols)
	# 山脉 ∧ 符号：每 ∧ 两条边并入单次 draw_multiline（原逐符号 2 次 draw_line）
	var mtn_col := _dim_color(Color(0.6, 0.52, 0.42, 0.55), df)
	var spacing := 34.0 * px
	var mtn_segs := PackedVector2Array()
	for r in DB.geo_rich.get("mountain_ranges", []):
		var wpts: Array = r.get("wpts", [])
		if wpts.size() < 2:
			continue
		var carry := 0.0
		for i in range(1, wpts.size()):
			var a: Vector2 = wpts[i - 1]
			var b: Vector2 = wpts[i]
			var seg_len := a.distance_to(b)
			var ang := (b - a).angle()
			var t := carry
			while t <= seg_len:
				var p := a.lerp(b, t / maxf(seg_len, 0.001))
				var up := Vector2(-sin(ang), -cos(ang)) * 7.0 * px
				var along := Vector2(sin(ang), -cos(ang)).orthogonal() * 5.0 * px
				mtn_segs.push_back(p - up * 0.9 + along)
				mtn_segs.push_back(p + up)
				mtn_segs.push_back(p + up)
				mtn_segs.push_back(p - up * 0.9 - along)
				t += spacing
			carry = t - seg_len
	if mtn_segs.size() >= 2:
		draw_multiline(mtn_segs, mtn_col, 1.6 * px, true)
	# 京杭大运河（虚线）
	var canal: Dictionary = DB.geo_rich.get("canal", {})
	var cw: Array = canal.get("wpts", [])
	for i in range(1, cw.size()):
		draw_dashed_line(cw[i - 1], cw[i], _dim_color(Color(0.4, 0.68, 0.82, 0.45), df),
				1.6 * px, 9.0 * px)
	# 补充河流
	for rv in DB.geo_rich.get("rivers", []):
		var rw: Array = rv.get("wpts", [])
		if rw.size() >= 2:
			draw_polyline(rw, COL_WATER, float(rv.get("w", 2.0)) * px * 0.55, true)
	# 补充湖泊
	for g in DB.geo_rich.get("lakes", []):
		if not g.has("wpos"):
			continue
		draw_set_transform(g["wpos"], 0.0, Vector2(g["wrx"], g["wry"]))
		draw_circle(Vector2.ZERO, 1.0, COL_WATER * Color(1, 1, 1, 0.75))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# 贪心抽稀：保留点间距 >= ~3.5 屏幕像素（等距采样对密集站场无效）；
# 线段对按「线|缩放桶」缓存，重放零重建
func _get_line_segs(line_id: String, wpts: PackedVector2Array, zoom: float) -> PackedVector2Array:
	var bucket := 0
	if zoom > 0.0:
		bucket = int(round(log(maxf(zoom, 1.0e-5)) / log(2.0)))
	var ck := str(line_id) + "|" + str(bucket)
	var segs: PackedVector2Array = _seg_cache.get(ck, PackedVector2Array())
	if segs.is_empty():
		var pts: PackedVector2Array = _lod_cache.get(ck, PackedVector2Array())
		if pts.is_empty():
			var min_d := 3.5 / maxf(zoom, 1.0e-6)
			pts = PackedVector2Array()
			pts.push_back(wpts[0])
			var last := wpts[0]
			for li in range(1, wpts.size()):
				var p := wpts[li]
				if p.distance_to(last) >= min_d:
					pts.push_back(p)
					last = p
			var lastp := wpts[wpts.size() - 1]
			if pts[pts.size() - 1] != lastp:
				pts.push_back(lastp)
			if _lod_cache.size() > 4000:
				_lod_cache.clear()
			_lod_cache[ck] = pts
		for li2 in range(1, pts.size()):
			segs.push_back(pts[li2 - 1])
			segs.push_back(pts[li2])
		if _seg_cache.size() > 4000:
			_seg_cache.clear()
		_seg_cache[ck] = segs
	return segs


# 一次性把路网记录进 RS canvas item（重录约 0.5~1s，仅在缩放桶跨越时发生）
func _rebuild_rs_lines(zoom: float) -> void:
	for rid in _rs_items:
		RenderingServer.free_rid(rid)
	_rs_items = []
	var zb := pow(2.0, float(_rs_bucket))
	var px0 := 1.0 / maxf(zb, 1.0e-6)
	var wf0: float = clampf(zb / 0.01, 0.55, 1.0)
	var aa: bool = zb > 0.004
	for line_id in DB.line_order:
		if Meta.is_focus_line(line_id):
			continue
		var line: Dictionary = DB.lines[line_id]
		if not Meta.is_class_visible(DB.line_class(line_id)):
			continue
		var wpts: PackedVector2Array = line["wpts"]
		var segs := _get_line_segs(line_id, wpts, zoom)
		if segs.size() < 2:
			continue
		var cls := DB.line_class(line_id)
		var core_w: float = float(CLASS_WIDTH.get(cls, 4.5))
		var core_col: Color = line["color"]
		var ci := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(ci, _line_host.get_canvas_item())
		# 底色描边 + 彩色芯线（全国视野略去底色层，顶点量减半）
		# 注意：RS add_multiline 的 colors 只接受「单色」或「每段两色」
		if zb >= 0.004:
			RenderingServer.canvas_item_add_multiline(ci, segs,
					PackedColorArray([COL_LINE_BASE]), (core_w + 5.0) * wf0 * px0, aa)
		RenderingServer.canvas_item_add_multiline(ci, segs,
				PackedColorArray([core_col]), core_w * wf0 * px0, aa)
		# OSM 缺口段虚线（逐缺口铺 dash 线段对）
		var dash_segs := PackedVector2Array()
		var dash_c: Color = core_col.lightened(0.35)
		var dash_w := core_w * wf0 * px0
		var dash_step := 10.0 * px0
		for gr in line.get("gap_ranges", []):
			var ga: Vector2 = wpts[gr[0]]
			var gb: Vector2 = wpts[gr[1]]
			var glen := ga.distance_to(gb)
			if glen * zb < 6.0:
				continue
			var nd := int(glen / dash_step)
			for di in range(nd):
				if di % 2 == 1:
					continue  # 空段（虚线）
				dash_segs.push_back(ga.lerp(gb, float(di) / float(nd)))
				dash_segs.push_back(ga.lerp(gb, minf(float(di + 1) / float(nd), 1.0)))
		if dash_segs.size() >= 2:
			RenderingServer.canvas_item_add_multiline(ci, dash_segs,
					PackedColorArray([dash_c]), dash_w, false)
		RenderingServer.canvas_item_set_visible(ci, true)
		_rs_items.append(ci)
	if OS.get_environment("RS_DEBUG") != "":
		print("[map] RS rebuild bucket=%d items=%d" % [_rs_bucket, _rs_items.size()])


func _draw_stations(px: float, df: float, view: Rect2, zoom: float) -> void:
	# 性能：按站名去重 + 视口裁剪 + 全国视野只画枢纽站；填充与环全部
	# 并入单次三角批/单次 draw_multiline（原每站 2 次 draw_call）。
	var seen := {}
	var ring_segs := PackedVector2Array()
	var dot_idx := PackedInt32Array()
	var dot_pts := PackedVector2Array()
	var dot_cols := PackedColorArray()
	var d_base := 0
	var ring_c := _dim_color(COL_STATION_RING, 0.35 + 0.65 * df)
	for line_id in DB.line_order:
		if Meta.is_focus_line(line_id):
			continue
		var line: Dictionary = DB.lines[line_id]
		if not Meta.is_class_visible(DB.line_class(line_id)):
			continue
		var line_st: Dictionary = line["stations"]
		for sid in line["order"]:
			var st: Dictionary = line_st[sid]
			var pos: Vector2 = st["pos"]
			if not view.has_point(pos):
				continue
			var key := str(st["name"])
			if seen.has(key):
				continue
			seen[key] = true
			var major: bool = st["major"]
			if zoom < 0.004 and not major:
				continue
			var r := (5.0 if major else 3.2) * px
			dot_pts.push_back(pos + Vector2(0, -r))
			dot_pts.push_back(pos + Vector2(r, 0))
			dot_pts.push_back(pos + Vector2(0, r))
			dot_pts.push_back(pos + Vector2(-r, 0))
			dot_idx.append_array(PackedInt32Array([d_base, d_base + 1, d_base + 2,
					d_base, d_base + 2, d_base + 3]))
			for _k in range(4):
				dot_cols.push_back(COL_STATION_FILL)
			d_base += 4
			# 环：10 段近似圆并入线段批
			var prev := pos + Vector2(r, 0)
			for k2 in range(1, 11):
				var cur := pos + Vector2(cos(TAU * k2 / 10.0), sin(TAU * k2 / 10.0)) * r
				ring_segs.push_back(prev)
				ring_segs.push_back(cur)
				prev = cur
	if d_base > 0:
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(),
				dot_idx, dot_pts, dot_cols)
	if ring_segs.size() >= 2:
		draw_multiline(ring_segs, ring_c, 1.4 * px, true)
	# 站名由 LabelLayer（屏幕空间）绘制

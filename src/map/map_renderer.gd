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


func _process(_delta: float) -> void:
	queue_redraw()


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
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	var px := 1.0 / zoom
	var df := daylight_factor(GameTime.t)
	var wf: float = clampf(zoom / 0.01, 0.55, 1.0)
	# 天空背景
	var sky := _sky_color(df)
	draw_rect(Rect2(Vector2(-2e6, -2e6), Vector2(6e6, 6e6)), sky)
	_draw_graticule(px)
	_draw_geography(px)
	_draw_line(px, wf, df)
	_draw_stations(px, df)


func _draw_graticule(px: float) -> void:
	for lon in range(80, 133):
		var a := GeoScript.lonlat_to_world(float(lon), 17.5)
		var b := GeoScript.lonlat_to_world(float(lon), 54.0)
		draw_line(a, b, COL_GRATICULE, maxf(px, 1.0), true)
	for lat in range(18, 54):
		var a := GeoScript.lonlat_to_world(79.0, float(lat))
		var b := GeoScript.lonlat_to_world(133.0, float(lat))
		draw_line(a, b, COL_GRATICULE, maxf(px, 1.0), true)


func _draw_geography(px: float) -> void:
	var bg := DB.background
	# 省级行政边界：淡填充 + 细边线
	for prov in bg.get("provinces", []):
		for wpts in prov["polys"]:
			if wpts.size() < 3:
				continue
			draw_colored_polygon(wpts, Color(0.10, 0.14, 0.21, 0.55))
			draw_polyline(wpts, Color(0.32, 0.40, 0.52, 0.8), 1.1 * maxf(px, 1.0), true)
	for coast in bg.get("wcoastlines", []):
		draw_polyline(coast, Color(0.45, 0.58, 0.72, 0.5), 1.5 * px, true)

	for river in bg.get("rivers", []):
		draw_polyline(river["wpts"], COL_WATER, 3.5 * px, true)

	for lake in bg.get("lakes", []):
		draw_set_transform(lake["wpos"], 0.0, Vector2(lake["wrx"] / lake["wry"], 1.0))
		draw_circle(Vector2.ZERO, lake["wry"], COL_WATER * Color(1, 1, 1, 0.6))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	for pl in bg.get("province_labels", []):
		pass  # 省份标注由 LabelLayer 绘制

	for c in bg.get("cities", []):
		var pos: Vector2 = c["wpos"]
		var major: bool = c.get("major", false)
		draw_circle(pos, (3.0 if major else 2.0) * px, Color(0.82, 0.87, 0.95, 0.75))


const CLASS_WIDTH := {"hsr350": 5.5, "hsr250": 4.5, "intercity": 4.0, "conventional": 2.6, "freight": 3.2}

func _draw_line(px: float, wf: float, df: float) -> void:
	for line_id in DB.line_order:
		if Meta.is_focus_line(line_id):
			continue
		var line: Dictionary = DB.lines[line_id]
		if not Meta.is_class_visible(DB.line_class(line_id)):
			continue
		var pts := PackedVector2Array()
		for p in line["geometry_pts"]:
			pts.append(p["pos"])
		var core: float = float(CLASS_WIDTH.get(DB.line_class(line_id), 4.5))
		var base_c := _dim_color(COL_LINE_BASE, df)
		var line_c := _dim_color(line["color"], 0.4 + 0.6 * df)
		draw_polyline(pts, base_c, (core + 5.0) * wf * px, true)
		draw_polyline(pts, line_c, core * wf * px, true)


func _draw_stations(px: float, df: float) -> void:
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
			var major: bool = st["major"]
			var r := (5.0 if major else 3.2) * px
			var ring_c := _dim_color(COL_STATION_RING, 0.35 + 0.65 * df)
			draw_circle(pos, r, COL_STATION_FILL)
			draw_arc(pos, r, 0.0, TAU, 24, ring_c, 1.4 * px, true)
		# 站名由 LabelLayer（屏幕空间）绘制

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


func _draw() -> void:
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	var px := 1.0 / zoom

	var wf: float = clampf(zoom / 0.01, 0.55, 1.0)
	_draw_graticule(px)
	_draw_geography(px)
	_draw_line(px, wf)
	_draw_stations(px)


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


func _draw_line(px: float, wf: float) -> void:
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		var pts := PackedVector2Array()
		for p in line["geometry_pts"]:
			pts.append(p["pos"])
		draw_polyline(pts, COL_LINE_BASE, 11.0 * wf * px, true)
		draw_polyline(pts, line["color"], 5.5 * wf * px, true)


func _draw_stations(px: float) -> void:
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		for sid in line["order"]:
			var st: Dictionary = line["stations"][sid]
			var pos: Vector2 = st["pos"]
			var major: bool = st["major"]
			var r := (5.0 if major else 3.2) * px
			draw_circle(pos, r, COL_STATION_FILL)
			draw_arc(pos, r, 0.0, TAU, 24, COL_STATION_RING, 1.4 * px, true)
		# 站名由 LabelLayer（屏幕空间）绘制

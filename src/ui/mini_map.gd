# 小地图：右下角全网概览，显示所有线路缩略 + 当前视野框，
# 点击可跳转到对应位置。使用固定缩放映射全国范围到面板大小。
extends Control

signal jump_requested(world_pos: Vector2)

const COL_BG := Color(0.06, 0.08, 0.12, 0.9)
const COL_LINE := Color(0.35, 0.42, 0.55, 0.7)
const COL_VIEWPORT := Color(1, 1, 1, 0.35)

var _geo_cache: Array = []  # [{line_color, points: PackedVector2Array}]（归一化 0-1）
var _bounds := Rect2()


func _ready() -> void:
	custom_minimum_size = Vector2(180, 140)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_cache()


func _build_cache() -> void:
	_geo_cache.clear()
	# 全国范围
	var min_x := 1.0e18
	var min_y := 1.0e18
	var max_x := -1.0e18
	var max_y := -1.0e18
	var all_wpts: Array = []
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		var wpts := PackedVector2Array()
		for p in line["geometry_pts"]:
			var pos: Vector2 = p["pos"]
			wpts.append(pos)
			min_x = minf(min_x, pos.x)
			min_y = minf(min_y, pos.y)
			max_x = maxf(max_x, pos.x)
			max_y = maxf(max_y, pos.y)
		all_wpts.append({"color": line["color"], "pts": wpts})
	_bounds = Rect2(min_x, min_y, max_x - min_x, max_y - min_y)

	# 归一化到 0-1
	for entry in all_wpts:
		var norm := PackedVector2Array()
		for p in entry["pts"]:
			norm.append(Vector2(
				(p.x - min_x) / (max_x - min_x),
				(p.y - min_y) / (max_y - min_y)))
		_geo_cache.append({"color": entry["color"], "pts": norm})


func _process(_delta: float) -> void:
	queue_redraw()


func _world_to_mini(world_pos: Vector2) -> Vector2:
	var b := _bounds
	var margin := 8.0
	var w := size.x - margin * 2
	var h := size.y - margin * 2
	return Vector2(
		margin + (world_pos.x - b.position.x) / b.size.x * w,
		margin + (world_pos.y - b.position.y) / b.size.y * h)


func _mini_to_world(mpos: Vector2) -> Vector2:
	var b := _bounds
	var margin := 8.0
	var w := size.x - margin * 2
	var h := size.y - margin * 2
	return Vector2(
		b.position.x + (mpos.x - margin) / w * b.size.x,
		b.position.y + (mpos.y - margin) / h * b.size.y)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	var cam := get_viewport().get_camera_2d()
	if cam == null or _geo_cache.is_empty():
		return
	var zoom := cam.zoom.x
	var cam_center: Vector2 = cam.get_screen_center_position()
	var vp_size: Vector2 = get_viewport_rect().size / zoom

	# 线路缩略
	for entry in _geo_cache:
		var pts := PackedVector2Array()
		for p in entry["pts"]:
			pts.append(Vector2(8 + p.x * (size.x - 16), 8 + p.y * (size.y - 16)))
		draw_polyline(pts, COL_LINE, 1.0, true)

	# 视野框
	var half := vp_size * 0.5 / zoom
	var tl := _world_to_mini(cam_center - half)
	var br := _world_to_mini(cam_center + half)
	var vr := Rect2(tl, br - tl)
	draw_rect(vr, COL_VIEWPORT, false, 1.2)

	# 在途列车点
	var active := 0
	for code in Simulation.states:
		var st: Dictionary = Simulation.states[code]
		if str(st.get("status", "")) not in ["run", "stop"]:
			continue
		var mp := _world_to_mini(st["pos"])
		if Rect2(Vector2.ZERO, size).has_point(mp):
			draw_circle(mp, 1.2, Color(1, 1, 1, 0.5))
			active += 1
			if active > 200:
				break

	# 边框
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.2, 0.25, 0.35), false, 1.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var margin := 8.0
		var w := size.x - margin * 2
		var h := size.y - margin * 2
		var wx := clampf((event.position.x - margin) / w, 0.0, 1.0)
		var wy := clampf((event.position.y - margin) / h, 0.0, 1.0)
		var b := _bounds
		jump_requested.emit(Vector2(
			b.position.x + wx * b.size.x,
			b.position.y + wy * b.size.y))

# 站场视图覆盖层：显示车站周边（4km）的 OSM 真实轨道布局。
# 数据来自该站所属线路的 OSM 缓存（含站场/渡线/正线全部 rail way）。
# 支持滚轮缩放（以鼠标为中心）与左键拖拽平移，Esc/关闭按钮退出。
extends Control

const UIKit := preload("res://src/ui/ui_kit.gd")
const FontLib := preload("res://src/ui/font_lib.gd")
const GeoScript := preload("res://src/core/geo.gd")

const VIEW_RADIUS_M := 4000.0   # 采集半径
const OSMDIR := "res://tools/cache12306/osm"

var sname := ""
var center := Vector2.ZERO
var tracks: Array = []          # [{pts: PackedVector2Array(world), named: bool, len: float}]
var adj_names: Array = []       # 邻站提示 [{name, pos, dir}]
var _loaded_for := ""
var _zoom := 1.0
var _offset := Vector2.ZERO
var _dragging := false
var _drag_start_mouse := Vector2.ZERO
var _drag_start_offset := Vector2.ZERO
var _mouse := Vector2.ZERO
var title_label: Label
var hint_label: Label
var empty_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	title_label = UIKit.label("", 20, Color.WHITE)
	title_label.position = Vector2(24, 18)
	add_child(title_label)
	hint_label = UIKit.label("滚轮缩放 · 左键拖拽平移 · [Esc] 退出", 12, Color(0.55, 0.62, 0.72))
	hint_label.position = Vector2(24, 52)
	add_child(hint_label)
	var close_btn := UIKit.button("× 退出站场", func(): visible = false)
	close_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	close_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(close_btn)
	empty_label = UIKit.label("该站周边暂无 OSM 站场数据。", 16, Color(0.7, 0.75, 0.85))
	empty_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	empty_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	empty_label.visible = false
	add_child(empty_label)


func open(station_name: String, pos: Vector2) -> void:
	sname = station_name
	center = pos
	_loaded_for = ""
	_zoom = 1.0
	_offset = Vector2.ZERO
	visible = true
	empty_label.visible = false
	title_label.text = "站场视图 · %s" % sname
	_load_tracks(sname, pos)
	queue_redraw()


func _load_tracks(station_name: String, pos: Vector2) -> void:
	tracks = []
	adj_names = []
	# 找到包含该站的线路 → 对应的 OSM 缓存文件
	var files := {}
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		var j := -1
		for i in range(line["order"].size()):
			if str(line["stations"][line["order"][i]]["name"]) == station_name:
				j = i
				break
		if j < 0:
			continue
		for k in [j - 1, j]:
			var fp := "%s/%s__%d.json" % [OSMDIR, line_id, k]
			if k >= 0 and FileAccess.file_exists(fp):
				files[fp] = true
		var fw := "%s/%s.json" % [OSMDIR, line_id]
		if FileAccess.file_exists(fw):
			files[fw] = true
	var seen_ways := {}
	for fp in files.keys():
		var f := FileAccess.open(fp, FileAccess.READ)
		if f == null:
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		for el in parsed.get("elements", []):
			if el.get("type") != "way":
				continue
			var wid = el.get("id")
			if seen_ways.has(wid):
				continue
			var geom: Array = el.get("geometry", [])
			if geom.size() < 2:
				continue
			var all_pts := PackedVector2Array()
			for p in geom:
				all_pts.append(GeoScript.lonlat_to_world(float(p["lon"]), float(p["lat"])))
			# 近站裁剪：把 way 切成 ≤(半径+2km) 的连续段，丢弃远端长尾
			var runs := []
			var run := PackedVector2Array()
			for w in all_pts:
				if w.distance_to(pos) <= VIEW_RADIUS_M + 3000.0:
					run.append(w)
				elif run.size() >= 2:
					runs.append(run)
					run = PackedVector2Array()
				else:
					run = PackedVector2Array()
			if run.size() >= 2:
				runs.append(run)
			if runs.is_empty():
				continue
			seen_ways[wid] = true
			var tags: Dictionary = el.get("tags", {})
			var wname: String = str(tags.get("name", ""))
			for r in runs:
				tracks.append({"pts": r, "named": wname != "", "len": _poly_len(r)})
	# 相邻站提示：取该站所属线路的左右邻站
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		var order: Array = line["order"]
		for i in range(order.size()):
			var sid: String = order[i]
			if str(line["stations"][sid]["name"]) != station_name:
				continue
			if i > 0:
				var psid: String = order[i - 1]
				adj_names.append({"name": str(line["stations"][psid]["name"]),
						"pos": line["stations"][psid]["pos"], "dir": -1})
			if i < order.size() - 1:
				var nsid: String = order[i + 1]
				adj_names.append({"name": str(line["stations"][nsid]["name"]),
						"pos": line["stations"][nsid]["pos"], "dir": 1})
			break
	_loaded_for = station_name


func _poly_len(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	return total


func _fit_view(view_size: Vector2) -> void:
	var mn := Vector2.INF
	var mx := -Vector2.INF
	for tr in tracks:
		for p in tr["pts"]:
			mn = mn.min(p)
			mx = mx.max(p)
	if mn == Vector2.INF:
		return
	var size := (mx - mn).max(Vector2(300, 300))
	_zoom = minf(view_size.x * 0.86 / size.x, view_size.y * 0.74 / size.y)
	var center := (mn + mx) * 0.5
	_offset = -center * _zoom + view_size * 0.5 + Vector2(0, 14)


func _draw() -> void:
	if not visible:
		return
	var vs := size
	draw_rect(Rect2(Vector2.ZERO, vs), Color(0.02, 0.03, 0.05, 0.97))
	# 首次打开或窗口变化时自动适配
	if tracks.size() > 0 and _zoom == 1.0 and _offset == Vector2.ZERO:
		_fit_view(vs)
	if tracks.is_empty():
		return
	# 背景网格
	var grid_c := Color(0.10, 0.14, 0.20, 0.5)
	var step := 64.0
	var x := fposmod(_offset.x, step)
	while x < vs.x:
		draw_line(Vector2(x, 60), Vector2(x, vs.y - 40), grid_c, 1.0)
		x += step
	var y := 60.0 + fposmod(_offset.y, step)
	while y < vs.y - 40:
		draw_line(Vector2(0, y), Vector2(vs.x, y), grid_c, 1.0)
		y += step
	# 轨道：命名正线亮、匿名侧线暗；长轨画粗细两级
	for tr in tracks:
		var col := Color(0.85, 0.9, 1.0, 0.9) if tr["named"] else Color(0.55, 0.6, 0.7, 0.55)
		var w := 2.2 if tr["named"] else 1.4
		var pts := PackedVector2Array()
		for p in tr["pts"]:
			pts.append(p * _zoom + _offset)
		draw_polyline(pts, col, w, true)
	# 中心站标记
	var cpos := center * _zoom + _offset
	draw_circle(cpos, 7.0, Color(0.95, 0.72, 0.3))
	draw_arc(cpos, 12.0, 0.0, TAU, 32, Color(0.95, 0.72, 0.3, 0.8), 1.5, true)
	# 相邻站提示
	var font := FontLib.get_font()
	for a in adj_names:
		var p: Vector2 = a["pos"] * _zoom + _offset
		if p.x < -40 or p.x > vs.x + 40 or p.y < -40 or p.y > vs.y + 40:
			continue
		var dirv: Vector2 = (p - cpos).normalized()
		var tip := p + dirv * 26.0
		draw_line(p + dirv * 12.0, tip, Color(0.6, 0.68, 0.8, 0.6), 1.0)
		var wsize := font.get_string_size(a["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		var tp := tip + dirv * 4.0 - Vector2(wsize.x * 0.5, -2)
		draw_string(font, tp, a["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				Color(0.7, 0.78, 0.9, 0.75))


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var over := get_global_rect().has_point(mb.position)
		if not over:
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, 1.15)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, 1.0 / 1.15)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_drag_start_mouse = mb.position
			_drag_start_offset = _offset
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_offset += mm.position - _drag_start_mouse
		_drag_start_mouse = mm.position
		queue_redraw()
	else:
		return
	queue_redraw()


func _zoom_at(mouse_pos: Vector2, factor: float) -> void:
	var before := mouse_pos
	var world := (before - _offset) / _zoom
	_zoom = clampf(_zoom * factor, 0.15, 40.0)
	_offset = before - world * _zoom
	queue_redraw()

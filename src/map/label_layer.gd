# 屏幕空间文字标注层：省份/城市/车站/列车车次/机位的文字全部用真实
# Label 节点绘制，每帧由世界坐标换算屏幕位置。规避 draw_string 不支持
# 画笔变换缩放、以及世界字号超字形位图上限的两个渲染问题。
extends CanvasLayer

const FontLib := preload("res://src/ui/font_lib.gd")

var selected := ""
var hover := ""

var _root: Control
var _font: Font
var _province: Array = []
var _cities: Array = []
var _stations: Array = []
var _trains: Array = []
var _spots: Array = []


func _ready() -> void:
	layer = 4
	_font = FontLib.get_font()
	_root = Control.new()
	_root.name = "Labels"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	for pl in DB.background.get("province_labels", []):
		var l := _mk(30.0, Color(1, 1, 1, 0.07), false)
		l.text = pl["name"]
		_province.append({"label": l, "wpos": pl["wpos"]})
	for c in DB.background.get("cities", []):
		var major: bool = c.get("major", false)
		var cl := _mk(14.0 if major else 11.0, Color(0.85, 0.89, 0.96, 0.6 if major else 0.42))
		cl.text = c["name"]
		_cities.append({"label": cl, "wpos": c["wpos"]})
	var seen_stations := {}
	for line_id in DB.line_order:
		if not Meta.is_class_visible(DB.line_class(line_id)):
			continue
		var line: Dictionary = DB.lines[line_id]
		for sid in line["order"]:
			var st: Dictionary = line["stations"][sid]
			var key := "%s|%.0f|%.0f" % [st["name"], st["pos"].x, st["pos"].y]
			if seen_stations.has(key):
				continue  # 多线共站（如北京南）只标注一次
			seen_stations[key] = true
			var sl := _mk(15.0 if st["major"] else 11.5,
					Color("dbe2ee") if st["major"] else Color(0.72, 0.77, 0.86, 0.85),
					st["major"])
			sl.text = st["name"]
			var kl := _mk(9.0, Color(0.6, 0.66, 0.76, 0.7), false)
			kl.text = "K%d" % int(st["km"])
			_stations.append({
				"label": sl, "km": kl,
				"wpos": st["pos"], "major": bool(st["major"])
			})
	for i in range(160):
		_trains.append(_mk(11.0, Color(0.95, 0.97, 1.0, 0.92)))
	for i in range(6):
		_spots.append(_mk(11.0, Color(0.7, 0.82, 1.0, 0.9)))


func _mk(size: float, color: Color, shadow := true) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font = _font
	ls.font_size = int(size)
	ls.font_color = color
	if shadow:
		ls.shadow_color = Color(0, 0, 0, 0.6)
		ls.shadow_offset = Vector2(1, 1)
	l.label_settings = ls
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(l)
	return l


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return
	var zoom := cam.zoom.x
	var half := _root.size * 0.5
	var center: Vector2 = cam.get_screen_center_position()
	var rect := Rect2(Vector2.ZERO, _root.size).grow(60.0)

	var show_station := zoom > 0.02
	var show_km := zoom > 0.055
	for e in _province:
		_place(e["label"], e["wpos"], center, half, zoom, rect, Vector2(-30, -20), true)
	for e in _cities:
		_place(e["label"], e["wpos"], center, half, zoom, rect, Vector2(6, -16), true)
	for e in _stations:
		var vis: bool = e["major"] or show_station
		_place(e["label"], e["wpos"], center, half, zoom, rect, Vector2(9, -21), vis)
		_place(e["km"], e["wpos"], center, half, zoom, rect, Vector2(9, 4), vis and show_km)
	_sync_trains(center, half, zoom, rect)
	_sync_spots(center, half, zoom, rect)


func _place(label: Label, wpos: Vector2, center: Vector2, half: Vector2,
		zoom: float, rect: Rect2, offset: Vector2, visible: bool) -> void:
	if not visible:
		label.visible = false
		return
	var sp := (wpos - center) * zoom + half + offset
	if not rect.has_point(sp):
		label.visible = false
		return
	label.visible = true
	label.position = sp


func _active(st: Dictionary) -> bool:
	var s: String = st.get("status", "off")
	return s == "run" or s == "stop" or s == "wait"


func _sync_trains(center: Vector2, half: Vector2, zoom: float, rect: Rect2) -> void:
	var show_all := zoom > 0.012
	var used := 0
	for code in Simulation.states:
		var st: Dictionary = Simulation.states[code]
		if not _active(st):
			continue
		var force: bool = code == selected or code == hover
		if not show_all and not force:
			continue
		var sp: Vector2 = (st["pos"] - center) * zoom + half
		if not rect.has_point(sp):
			continue
		if used >= _trains.size():
			if not force:
				continue
			used = _trains.size() - 1  # 池满时复用最后一个槽位给选中车
		var l: Label = _trains[used]
		used += 1
		l.visible = true
		l.text = code
		var tt: Dictionary = DB.train_types.get(st["type"], {})
		var col: Color = Color(tt.get("color", "#ffffff"))
		l.label_settings.font_color = Color.WHITE if force else col.lightened(0.45)
		l.position = sp + Vector2(0, -19)
	for i in range(used, _trains.size()):
		_trains[i].visible = false


func _sync_spots(center: Vector2, half: Vector2, zoom: float, rect: Rect2) -> void:
	for i in range(_spots.size()):
		var l: Label = _spots[i]
		if i >= Meta.spots.size():
			l.visible = false
			continue
		var s: Dictionary = Meta.spots[i]
		_place(l, s["world"], center, half, zoom, rect, Vector2(14, -24), true)
		if l.visible:
			l.text = "%s · %.0f km" % [s["name"], s["r_m"] / 1000.0]

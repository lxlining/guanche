# 列车层：绘制全部在途列车标记、悬停/选中高亮、点选拾取，
# 并驱动观测判定（机位捕捉、同屏数量统计）。
extends Node2D

signal train_clicked(code: String)

var selected := ""
var hover := ""

var _mouse_world := Vector2.ZERO


func _process(_delta: float) -> void:
	_mouse_world = get_global_mouse_position()
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	_update_hover(zoom)
	_run_observation(zoom)
	queue_redraw()


func pick(world_pos: Vector2, zoom: float) -> String:
	var best := ""
	var best_d := 16.0 / zoom
	for code in Simulation.states:
		var st: Dictionary = Simulation.states[code]
		if not _is_active(st):
			continue
		var d: float = st["pos"].distance_to(world_pos)
		if d < best_d:
			best_d = d
			best = code
	return best


func _update_hover(zoom: float) -> void:
	hover = pick(_mouse_world, zoom)


func _run_observation(zoom: float) -> void:
	if GameTime.paused:
		return
	var t := GameTime.t
	for code in Simulation.states:
		var st: Dictionary = Simulation.states[code]
		if not _is_active(st):
			continue
		for s in Meta.spots:
			if st["pos"].distance_to(s["world"]) <= s["r_m"]:
				var sid: String = DB.nearest_station(st["line"], st["pos"])
				Meta.observe(code, st["type"], t, DB.station_name(st["line"], sid))
	# 同屏列车数统计（成就用）
	var vp := get_viewport_rect().size
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		var half := vp * 0.5
		var rect := Rect2(cam.get_screen_center_position() - half / zoom, vp / zoom)
		var n := 0
		for code in Simulation.states:
			var st: Dictionary = Simulation.states[code]
			if _is_active(st) and rect.has_point(st["pos"]):
				n += 1
		Meta.report_screen_trains(n)


func _is_active(st: Dictionary) -> bool:
	var s: String = st.get("status", "off")
	return s == "run" or s == "stop" or s == "wait"


func _draw() -> void:
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	var px := 1.0 / zoom

	# LOD：全国视野用小圆点，中景小箭头，近景完整箭头
	var dot_mode := zoom < 0.006
	var small := zoom < 0.015

	for code in Simulation.states:
		var st: Dictionary = Simulation.states[code]
		if not _is_active(st):
			continue
		var tt: Dictionary = DB.train_types.get(st["type"], {})
		var col: Color = Color(tt.get("color", "#e5484d"))
		var pos: Vector2 = st["pos"]

		if dot_mode:
			var c := col.lightened(0.15) if code == hover else col
			draw_circle(pos, (4.5 if code == selected else 3.0) * px, c)
			if code == selected:
				draw_arc(pos, 7.0 * px, 0.0, TAU, 20, Color.WHITE, 1.6 * px, true)
			continue

		var ang: float = (st["dirv"] as Vector2).angle()
		var sc: float = px * (0.7 if small else 1.0)
		draw_set_transform(pos, ang, Vector2.ONE * sc)
		var shape := PackedVector2Array([
			Vector2(14, 0), Vector2(-9, 5.5), Vector2(-5, 0), Vector2(-9, -5.5)
		]) if long_train(tt) else PackedVector2Array([
			Vector2(10, 0), Vector2(-6, 6), Vector2(-3, 0), Vector2(-6, -6)
		])
		var c2 := col.lightened(0.25) if code == hover and code != selected else col
		draw_colored_polygon(shape, c2)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

		if code == selected:
			draw_arc(pos, 13.0 * px, 0.0, TAU, 28, Color.WHITE, 2.0 * px, true)
		elif code == hover:
			draw_arc(pos, 13.0 * px, 0.0, TAU, 28, Color(1, 1, 1, 0.45), 1.5 * px, true)


func long_train(tt: Dictionary) -> bool:
	var fmt: String = str(tt.get("formation", "8"))
	return "16" in fmt or "17" in fmt
		# 车次文字由 LabelLayer（屏幕空间）绘制

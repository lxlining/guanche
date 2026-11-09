# 列车层：绘制全部在途列车标记、悬停/选中高亮、点选拾取，
# 并驱动观测判定（机位捕捉、同屏数量统计）。
extends Node2D

signal train_clicked(code: String)

var selected := ""
var hover := ""
var trail: Array = []  # 跟随列车尾迹（世界坐标）

# 选中列车全程走线缓存（切换选中时重建）：legs=各腿几何点列, stops=停站点
var _route_for := ""
var _route_legs: Array = []
var _route_stops := PackedVector2Array()

var _mouse_world := Vector2.ZERO
var _obs_accum := 0.0
var _last_mouse := Vector2(-1e9, -1e9)


func _process(delta: float) -> void:
	_mouse_world = get_global_mouse_position()
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	if selected != _route_for:
		_rebuild_route(selected)
	# 悬停拾取：仅鼠标移动时重算（万级遍历）
	if not _mouse_world.is_equal_approx(_last_mouse):
		_last_mouse = _mouse_world
		_update_hover(zoom)
	# 观测判定：4Hz 节流
	_obs_accum += delta
	if _obs_accum >= 0.5:
		_obs_accum = 0.0
		var ob0 := Time.get_ticks_usec()
		_run_observation(zoom)
		PerfProbe.lap("obs", Time.get_ticks_usec() - ob0)
	queue_redraw()


func _rebuild_route(code: String) -> void:
	_route_for = code
	_route_legs = []
	_route_stops = PackedVector2Array()
	if code == "" or not DB.train_by_code.has(code):
		return
	var train: Dictionary = DB.train_by_code[code]
	for leg in train["legs"]:
		var lid: String = str(leg["line"])
		if not DB.lines.has(lid):
			continue
		var pts := DB.geometry_between(lid, leg["arc0"], leg["arc1"])
		if pts.size() >= 2:
			_route_legs.append({"pts": pts, "color": DB.lines[lid]["color"]})
	for st in train["stops"]:
		var lid: String = str(st.get("line", ""))
		if lid != "" and st.get("arc", -1.0) >= 0.0:
			_route_stops.append(DB.arc_point(lid, st["arc"])["pos"])


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
	var st_arr: PackedByteArray = Simulation._status_arr
	var ps_arr: PackedVector2Array = Simulation._pos_arr
	var cd_arr: PackedStringArray = Simulation._codes
	var tp_arr: PackedStringArray = Simulation._type_arr
	var cl_arr: PackedStringArray = Simulation._cur_line
	var n: int = cd_arr.size()
	for ti in range(n):
		if st_arr[ti] == 0:
			continue
		var pos := ps_arr[ti]
		for s in Meta.spots:
			if pos.distance_to(s["world"]) <= s["r_m"]:
				var line_id: String = cl_arr[ti]
				var sid: String = DB.nearest_station(line_id, pos)
				Meta.observe(cd_arr[ti], tp_arr[ti], t,
						DB.station_name(line_id, sid))
	# 同屏列车数统计（成就用）
	var vp := get_viewport_rect().size
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		var half := vp * 0.5
		var rect := Rect2(cam.get_screen_center_position() - half / zoom, vp / zoom)
		var in_screen := 0
		for ti2 in range(n):
			if st_arr[ti2] != 0 and rect.has_point(ps_arr[ti2]):
				in_screen += 1
		Meta.report_screen_trains(in_screen)


func _train_on_line(train: Dictionary, line_id: String) -> bool:
	for leg in train.get("legs", []):
		if str(leg["line"]) == line_id:
			return true
	return false


func _is_active(st: Dictionary) -> bool:
	var s: String = st.get("status", "off")
	return s == "run" or s == "stop" or s == "wait"


func _draw() -> void:
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	var px := 1.0 / zoom

	# 选中列车全程走线：各腿沿线发光 + 停站点圆环
	if selected != "" and not _route_legs.is_empty():
		for r in _route_legs:
			var rc: Color = r["color"]
			draw_polyline(r["pts"], Color(rc.r, rc.g, rc.b, 0.22), 12.0 * px, true)
			draw_polyline(r["pts"], rc.lightened(0.62), 3.0 * px, true)
		for sp in _route_stops:
			draw_circle(sp, 2.2 * px, Color(0.08, 0.09, 0.12, 0.9))
			draw_arc(sp, 4.5 * px, 0.0, TAU, 14, Color(1, 1, 1, 0.85), 1.4 * px, true)

	# 选中/悬停列车的跨线 transfer 路径（沿联络线真实路径）
	for code in [selected, hover]:
		if code == "" or not DB.train_by_code.has(code):
			continue
		var train: Dictionary = DB.train_by_code[code]
		for trf in train["transfers"]:
			var tpts: PackedVector2Array = trf["pts"]
			if tpts.size() < 2:
				continue
			draw_polyline(tpts, Color(1, 1, 1, 0.30), 2.4 * px, true)
			draw_polyline(tpts, Color(0.1, 0.1, 0.15, 0.75), 1.0 * px, true)

	# LOD：全国视野用小圆点，中景小箭头，近景完整箭头
	var dot_mode := zoom < 0.006
	var small := zoom < 0.015
	# 形状/颜色外提：避免每车每帧重建 PackedVector2Array 与 Color(str)
	var shape_long := PackedVector2Array([
		Vector2(14, 0), Vector2(-9, 5.5), Vector2(-5, 0), Vector2(-9, -5.5)])
	var shape_std := PackedVector2Array([
		Vector2(10, 0), Vector2(-6, 6), Vector2(-3, 0), Vector2(-6, -6)])
	var type_colors := {}
	for tid in DB.train_types:
		type_colors[tid] = Color(str(DB.train_types[tid].get("color", "#e5484d")))
	# 视口裁剪（视野外列车跳过绘制）
	var cam2 := get_viewport().get_camera_2d()
	var view := Rect2()
	if cam2 != null:
		var vp := get_viewport().get_visible_rect().size
		view = Rect2(cam2.get_screen_center_position() - vp * 0.5 / zoom,
				vp / zoom).grow(40000.0)
	# 全国视野三角批渲染缓冲（单次 add_triangle_array，替代数千 draw_circle）
	var tri_idx := PackedInt32Array()
	var tri_pts := PackedVector2Array()
	var tri_cols := PackedColorArray()
	var tri_base := 0
	var sel_pos := Vector2.INF
	var hov_pos := Vector2.INF

	# 主循环走 Simulation 平行数组（直读，免函数调用开销）
	var st_arr: PackedByteArray = Simulation._status_arr
	var ps_arr: PackedVector2Array = Simulation._pos_arr
	var cd_arr: PackedStringArray = Simulation._codes
	var tp_arr: PackedStringArray = Simulation._type_arr
	var fr_arr: PackedByteArray = Simulation._freight_arr
	var dv_arr: PackedVector2Array = Simulation._dir_arr
	var cl_arr: PackedStringArray = Simulation._cur_line
	var n_trains: int = cd_arr.size()
	for ti in range(n_trains):
		if st_arr[ti] == 0:
			continue
		var code: String = cd_arr[ti]
		var tr_line: String = cl_arr[ti]
		# 专注过滤：车次专注只显示该车；线路专注只显示本线车次
		if Meta.focus_train != "" and code != Meta.focus_train:
			continue
		if Meta.focus_train == "" and Meta.focus_line != "" \
				and not Simulation.train_on_line_at(ti, Meta.focus_line):
			continue
		if Meta.is_focus_line(tr_line):
			continue
		if not Meta.is_class_visible(DB.line_class(tr_line)):
			continue
		var tr_type: String = tp_arr[ti]
		var col: Color = type_colors.get(tr_type, Color("#e5484d"))
		var pos: Vector2 = ps_arr[ti]
		if not view.has_point(pos):
			continue

		var is_freight: bool = fr_arr[ti] == 1
		if is_freight:
			col = Color("#c2833c")

		if dot_mode:
			# 方向菱形并入批缓冲；选中/悬停的车补画光环
			var d := dv_arr[ti].normalized()
			var nv := Vector2(-d.y, d.x)
			tri_pts.push_back(pos + d * 4.6 * px)
			tri_pts.push_back(pos + nv * 2.9 * px)
			tri_pts.push_back(pos - d * 4.6 * px)
			tri_pts.push_back(pos - nv * 2.9 * px)
			tri_idx.append_array(PackedInt32Array([tri_base, tri_base + 1, tri_base + 2,
					tri_base, tri_base + 2, tri_base + 3]))
			var cc := col.lightened(0.15) if code == hover else col
			for _k in range(4):
				tri_cols.push_back(cc)
			tri_base += 4
			if code == selected:
				sel_pos = pos
			elif code == hover:
				hov_pos = pos
			continue

		var dirv := dv_arr[ti]
		if is_freight:
			# 货车：方块标记（区别于客车箭头）
			var sz := 9.0 * px * (0.7 if small else 1.0)
			var ang_f: float = dirv.angle()
			draw_set_transform(pos, ang_f, Vector2.ONE * px * (0.7 if small else 1.0))
			var rect := Rect2(Vector2(-5, -4), Vector2(13, 8))
			draw_rect(rect, col)
			draw_rect(Rect2(Vector2(-8, -2.4), Vector2(3, 4.8)), col)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			if code == selected:
				draw_arc(pos, 13.0 * px, 0.0, TAU, 28, Color.WHITE, 2.0 * px, true)
			continue

		var ang: float = dirv.angle()
		var sc: float = px * (0.7 if small else 1.0)
		draw_set_transform(pos, ang, Vector2.ONE * sc)
		var c2 := col.lightened(0.25) if code == hover and code != selected else col
		draw_colored_polygon(shape_long if long_train(DB.train_types.get(tr_type, {})) else shape_std, c2)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

		# 跟随列车尾迹
		if code == selected and trail.size() >= 2:
			var tpts := PackedVector2Array()
			for tp in trail:
				tpts.append(tp)
			draw_polyline(tpts, Color(1, 1, 1, 0.12), 4.0 * px, true)
		if code == selected:
			draw_arc(pos, 13.0 * px, 0.0, TAU, 28, Color.WHITE, 2.0 * px, true)
		elif code == hover:
			draw_arc(pos, 13.0 * px, 0.0, TAU, 28, Color(1, 1, 1, 0.45), 1.5 * px, true)

	# 全国视野：一次调用提交全部列车菱形 + 选中/悬停光环
	if dot_mode and tri_base > 0:
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(),
				tri_idx, tri_pts, tri_cols)
		if sel_pos != Vector2.INF:
			draw_arc(sel_pos, 7.5 * px, 0.0, TAU, 20, Color.WHITE, 1.6 * px, true)
		if hov_pos != Vector2.INF:
			draw_arc(hov_pos, 7.5 * px, 0.0, TAU, 20, Color(1, 1, 1, 0.5), 1.4 * px, true)


func long_train(tt: Dictionary) -> bool:
	var fmt: String = str(tt.get("formation", "8"))
	return "16" in fmt or "17" in fmt
		# 车次文字由 LabelLayer（屏幕空间）绘制

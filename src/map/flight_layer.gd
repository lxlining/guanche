# 航班层：绘制机场圆点（尺寸按航线数）与在途航班（三角形按航向），
# 悬停/选中高亮，选中航班的航线弧加亮；拾取由 main 调 pick()/pick_airport()。
# 航班号与机场名文字由 LabelLayer（屏幕空间）绘制。
extends Node2D

var selected := -1
var hover := -1
var hover_ap := ""
var _mouse_world := Vector2.ZERO
var _states := {}      # idx -> state（0.2s 实时量化重建，供拾取与绘制复用）
var _airborne: Array = []
var _fl_accum := 0.0
var force_idx := -1    # 被跟随/选中的航班：每帧单独解算（相机平滑所需）


func _process(_delta: float) -> void:
	visible = Meta.aviation_on and FlightSim.ready_ok and not Meta.focus_active()
	if not visible:
		hover = -1
		hover_ap = ""
		_states = {}
		return
	var tf0 := Time.get_ticks_usec()
	# 状态缓存 0.2s 实时量化：低速时大幅省算力，高速时每帧重建（无损）
	_fl_accum += _delta
	var t := GameTime.t
	if _states.size() > 0 and _fl_accum < 0.2:
		# 被跟随/选中航班保持逐帧平滑
		if force_idx >= 0 and FlightSim.flights.size() > force_idx:
			var fst := FlightSim.state_for(force_idx, t)
			var fph: String = str(fst["phase"])
			if fph == "pre" or fph == "done":
				_airborne.erase(force_idx)
			else:
				_states[force_idx] = fst
				if not _airborne.has(force_idx):
					_airborne.append(force_idx)
		return
	_fl_accum = 0.0
	_states = {}
	_airborne = []
	for idx in FlightSim.active_flights(t):
		var st: Dictionary = FlightSim.state_for(idx, t)
		var ph: String = str(st["phase"])
		if ph == "pre" or ph == "done":
			continue
		_states[idx] = st
		_airborne.append(idx)
	PerfProbe.lap("fl_states", Time.get_ticks_usec() - tf0)
	_mouse_world = get_global_mouse_position()
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	hover = pick(_mouse_world, zoom)
	if hover < 0:
		hover_ap = pick_airport(_mouse_world, zoom)
	else:
		hover_ap = ""
	queue_redraw()


func pick(world_pos: Vector2, zoom: float) -> int:
	var best := -1
	var best_d := 14.0 / zoom
	for idx in _airborne:
		var st: Dictionary = _states[idx]
		var d: float = (st["pos"] as Vector2).distance_to(world_pos)
		if d < best_d:
			best_d = d
			best = idx
	return best


func pick_airport(world_pos: Vector2, zoom: float) -> String:
	var best := ""
	var best_d := 16.0 / zoom
	for iata in FlightSim.airports:
		var ap: Dictionary = FlightSim.airports[iata]
		var d: float = (ap["pos"] as Vector2).distance_to(world_pos)
		if d < best_d:
			best_d = d
			best = str(iata)
	return best


func _draw() -> void:
	if not visible:
		return
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	var px := 1.0 / zoom
	var t := GameTime.t

	# 机场圆点：菱形并入三角批（1 次提交），枢纽光环并入单次 draw_multiline
	var ap_idx := PackedInt32Array()
	var ap_pts := PackedVector2Array()
	var ap_cols := PackedColorArray()
	var ap_base := 0
	var halo_segs := PackedVector2Array()
	var hov_ap_pos := Vector2.INF
	var hov_ap_r := 0.0
	for iata in FlightSim.airports:
		var ap: Dictionary = FlightSim.airports[iata]
		var pos: Vector2 = ap["pos"]
		var major: bool = int(ap["major"]) == 1
		var n: int = ap["routes_n"]
		var r := (3.2 if major else 2.0) + minf(sqrt(float(n)) * 0.7, 6.0)
		var col := Color("#f2b03d") if major else Color("#c9a86a")
		col.a = 0.92
		ap_pts.push_back(pos + Vector2(0, -r * px))
		ap_pts.push_back(pos + Vector2(r * px, 0))
		ap_pts.push_back(pos + Vector2(0, r * px))
		ap_pts.push_back(pos + Vector2(-r * px, 0))
		ap_idx.append_array(PackedInt32Array([ap_base, ap_base + 1, ap_base + 2,
				ap_base, ap_base + 2, ap_base + 3]))
		for _k in range(4):
			ap_cols.push_back(col)
		ap_base += 4
		if major and zoom < 0.02:
			var rr := (r + 3.5) * px
			var prev := pos + Vector2(rr, 0)
			for k3 in range(1, 11):
				var cur := pos + Vector2(cos(TAU * k3 / 10.0), sin(TAU * k3 / 10.0)) * rr
				halo_segs.push_back(prev)
				halo_segs.push_back(cur)
				prev = cur
		if str(iata) == hover_ap:
			hov_ap_pos = pos
			hov_ap_r = r
	if ap_base > 0:
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(),
				ap_idx, ap_pts, ap_cols)
	if halo_segs.size() >= 2:
		draw_multiline(halo_segs, Color(1.0, 0.85, 0.5, 0.32), 1.2 * px, true)
	if hov_ap_pos != Vector2.INF:
		draw_arc(hov_ap_pos, (hov_ap_r + 6.0) * px, 0.0, TAU, 24, Color.WHITE, 1.6 * px, true)

	# 在途航班：普通飞机并入三角批缓冲（单次提交），选中/悬停单独高亮
	var small := zoom < 0.008
	var al_colors := {}
	for code2 in FlightSim.airlines:
		al_colors[code2] = Color(str(FlightSim.airlines[code2]["color"]))
	var tri_idx := PackedInt32Array()
	var tri_pts := PackedVector2Array()
	var tri_cols := PackedColorArray()
	var tri_base := 0
	for idx in _airborne:
		var st: Dictionary = _states[idx]
		var pos2: Vector2 = st["pos"]
		var fl: Dictionary = FlightSim.flights[idx]
		var col2: Color = al_colors.get(str(fl["al"]), Color("#3f7fe0"))
		var is_sel: bool = idx == selected
		var is_hov: bool = idx == hover
		if is_sel or is_hov:
			# 高亮机单独绘制（含航线弧）
			var sc := px * (0.75 if small else 1.0)
			draw_set_transform(pos2, float(st["heading"]), Vector2.ONE * sc)
			var hshape := PackedVector2Array([
				Vector2(11, 0), Vector2(-7, 4.5), Vector2(-4, 0), Vector2(-7, -4.5)])
			draw_colored_polygon(hshape, col2.lightened(0.3) if is_hov and not is_sel else col2)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			if is_sel:
				draw_arc(pos2, 12.0 * px, 0.0, TAU, 24, Color.WHITE, 2.0 * px, true)
				var r2: Dictionary = FlightSim.routes[fl["ri"]]
				var arc_col := col2.lightened(0.45)
				arc_col.a = 0.65
				draw_polyline(r2["path"], arc_col, 2.2 * px, true)
			else:
				draw_arc(pos2, 12.0 * px, 0.0, TAU, 24, Color(1, 1, 1, 0.45), 1.4 * px, true)
			continue
		# 普通机：3 顶点三角并入批缓冲
		var hd: float = float(st["heading"])
		var d := Vector2(cos(hd), sin(hd))
		var nv := Vector2(-d.y, d.x)
		var s2 := px * (0.75 if small else 1.0)
		tri_pts.push_back(pos2 + d * 11.0 * s2)
		tri_pts.push_back(pos2 - d * 7.0 * s2 + nv * 4.5 * s2)
		tri_pts.push_back(pos2 - d * 4.0 * s2)
		tri_pts.push_back(pos2 - d * 7.0 * s2 - nv * 4.5 * s2)
		tri_idx.append_array(PackedInt32Array([tri_base, tri_base + 1, tri_base + 2,
				tri_base, tri_base + 2, tri_base + 3]))
		for _k in range(4):
			tri_cols.push_back(col2)
		tri_base += 4
	if tri_base > 0:
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(),
				tri_idx, tri_pts, tri_cols)

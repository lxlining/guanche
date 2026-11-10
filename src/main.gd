# 主场景：组装地图/列车/机位/相机/UI，处理点选、跟随、快捷键与成就联动。
extends Node2D

const MapRenderer := preload("res://src/map/map_renderer.gd")
const CameraController := preload("res://src/map/camera_controller.gd")
const TrainLayer := preload("res://src/map/train_layer.gd")
const SpotLayer := preload("res://src/map/spot_layer.gd")
const LabelLayer := preload("res://src/map/label_layer.gd")
const FlightArcLayer := preload("res://src/map/flight_arc_layer.gd")
const FlightLayer := preload("res://src/map/flight_layer.gd")
const MainUI := preload("res://src/ui/main_ui.gd")

var cam: Camera2D
var trains_layer: Node2D
var flights_layer: Node2D
var label_layer: CanvasLayer
var ui: CanvasLayer

var selected := ""

var follow_code := ""
var follow_flight := -1     # 跟随航班 idx（-1 = 不跟随）
var _f_last_pos := Vector2(NAN, NAN)
var _f_dist := 0.0
var _f_started_at_departure := false
var _f_full_line := false
var _f_reported := true
var _cross_ready := true
var _station_accum := 0.0
var _save_accum := 0.0

# 截图调试模式（SHOT_MODE=map|diagram|list，SHOT_PATH=输出 png 绝对路径）
var _shot_mode := ""
var _shot_frame := -1


func _ready() -> void:
	var map := MapRenderer.new()
	map.name = "MapRenderer"
	add_child(map)
	var arcs := FlightArcLayer.new()
	arcs.name = "FlightArcLayer"
	add_child(arcs)
	var spots := SpotLayer.new()
	spots.name = "SpotLayer"
	add_child(spots)
	trains_layer = TrainLayer.new()
	trains_layer.name = "TrainLayer"
	add_child(trains_layer)
	flights_layer = FlightLayer.new()
	flights_layer.name = "FlightLayer"
	add_child(flights_layer)
	label_layer = LabelLayer.new()
	label_layer.name = "LabelLayer"
	add_child(label_layer)
	cam = CameraController.new()
	cam.name = "Camera"
	add_child(cam)
	ui = MainUI.new()
	ui.name = "UI"
	add_child(ui)

	trains_layer.connect("train_clicked", _on_train_clicked)
	ui.flight_card.connect("follow_requested", _toggle_flight_follow)
	ui.flight_picked.connect(_on_flight_pick)
	ui.train_list.connect("train_selected", _on_list_select)
	ui.detail.connect("follow_requested", _toggle_follow)
	ui.detail.connect("station_info_requested", _on_stop_station_click)
	ui.detail.connect("locate_requested", _locate)
	ui.detail.connect("focus_requested", _enter_train_focus)
	ui.station_card.connect("yard_requested", func(sname: String):
		if DB._name_pos.has(sname):
			ui.open_yard_view(sname, DB._name_pos[sname]))
	ui.detail.connect("closed", func(): _select(""))
	cam.connect("map_clicked", _on_map_click)
	cam.connect("map_right_clicked", _on_map_right_click)
	ui.diagram.connect("train_picked", _on_diagram_pick)
	ui.line_screen.connect("code_picked", _on_line_screen_pick)
	Meta.focus_line_changed.connect(_on_line_focus_camera)
	Meta.aviation_changed.connect(_on_aviation_view_switched)
	ui.train_search_picked.connect(_on_train_search_pick)
	if Meta.aviation_on and FlightSim.ready_ok:
		_on_aviation_view_switched.call_deferred()  # 存档为航空视图时启动即归位
	ui.cam_jump_requested.connect(func(wpos: Vector2):
		cam.follow_code = ""
		cam.position = wpos)

	if Meta.is_fresh:
		ui.help_panel.visible = true

	# 临时性能排查开关：PERF_SKIP=map,trains,flights,labels,minimap 逐层排除
	var skip := OS.get_environment("PERF_SKIP").split(",")
	for s in skip:
		match s:
			"map":
				get_node("MapRenderer").visible = false
			"trains":
				trains_layer.visible = false
			"flights":
				flights_layer.visible = false
				get_node("FlightArcLayer").visible = false
			"labels":
				label_layer.visible = false
			"minimap":
				ui.mini_map.visible = false

	_shot_mode = OS.get_environment("SHOT_MODE")
	if _shot_mode != "" and OS.get_environment("SHOT_PATH") != "":
		_shot_frame = 0
		if _shot_mode == "diagram":
			GameTime.jump_to(12, 0)


func _shot_tick() -> void:
	if _shot_frame < 0:
		return
	_shot_frame += 1
	if _shot_frame == 10 and _shot_mode == "diagnose":
		var bad := 0
		var total := 0
		for t_s in [21600.0, 43200.0, 64800.0]:
			for train in DB.trains:
				var st: Dictionary = Simulation.state_for(train, t_s)
				if str(st.get("status", "")) != "run":
					continue
				var st2: Dictionary = Simulation.state_for(train, t_s + 30.0)
				var move: Vector2 = st2["pos"] - st["pos"]
				if move.length() < 50.0:
					continue
				total += 1
				var dot: float = move.normalized().dot(st["dirv"])
				if dot < -0.5:
					bad += 1
					if bad <= 6:
						var st2b: Dictionary = Simulation.state_for(train, t_s + 30.0)
						print("DIAG-REVERSED %s line=%s dir=%s 首站=%s 末站=%s" % [
							train["code"], train["line"], train["dir"],
							train["stops"][0]["sid"], train["stops"][train["stops"].size() - 1]["sid"]])
		print("DIAG-SUMMARY total=%d reversed=%d" % [total, bad])
	if _shot_frame == 5:
		if _shot_mode == "line":
			ui.line_screen.open("jinghu_hsr")
			ui.close_overlays.call_deferred() if false else null
			ui.line_screen.visible = true
			_shot_mode = "line"
		match _shot_mode:
			"help":
				ui.help_panel.visible = true
			"dex":
				ui.toggle_dex()
			"ach":
				ui.toggle_ach()
			"night":
				GameTime.jump_to(23, 0)
			"detail":
				GameTime.jump_to(10, 0)
			"air":
				Meta.set_aviation(true)
				GameTime.jump_to(10, 0)
			"airfl":
				Meta.set_aviation(true)
				GameTime.jump_to(10, 0)
			_:
				ui.close_overlays()
	if _shot_frame == 8 and _shot_mode == "zoom":
		cam.position = DB.line("jinghu_hsr")["stations"]["jnx"]["pos"]
		cam.zoom = Vector2(0.03, 0.03)
	if _shot_frame == 8 and _shot_mode == "air":
		# 全国视野看航线网络（可 SHOT_LON/SHOT_LAT/SHOT_Z 定位）
		cam.follow_code = ""
		if OS.get_environment("SHOT_LON") != "":
			cam.position = Vector2((float(OS.get_environment("SHOT_LON")) - 118.85) * 90627.0,
					-(float(OS.get_environment("SHOT_LAT")) - 35.5) * 110574.0)
			var z := float(OS.get_environment("SHOT_Z"))
			cam.zoom = Vector2(z, z)
		else:
			cam.position = DB.map_center
			cam.zoom = Vector2(DB.fit_zoom * 1.02, DB.fit_zoom * 1.02)
	if _shot_frame == 8 and _shot_mode == "focus":
		# 模拟点击沪昆高铁线体：专注模式
		Meta.set_focus_line("hukun_hsr")
		var line: Dictionary = DB.line("hukun_hsr")
		cam.follow_code = ""
		cam.position = line["center"]
		cam.zoom = Vector2(line["fit_zoom"], line["fit_zoom"])
	if _shot_frame == 8 and _shot_mode == "at":
		# 通用定位截图：SHOT_LON/SHOT_LAT/SHOT_Z
		var lon := float(OS.get_environment("SHOT_LON"))
		var lat := float(OS.get_environment("SHOT_LAT"))
		var z := float(OS.get_environment("SHOT_Z"))
		cam.position = Vector2((lon - 118.85) * 90627.0, -(lat - 35.5) * 110574.0)
		cam.zoom = Vector2(z, z)
	if _shot_frame == 8 and _shot_mode == "zoom2":
		# 闽赣浙交界（用户圈注区域）
		cam.position = Vector2((117.9 - 118.85) * 90627.0, -(27.9 - 35.5) * 110574.0)
		cam.zoom = Vector2(0.004, 0.004)
	if _shot_frame == 20:
		match _shot_mode:
			"diagram":
				ui.toggle_diagram()
			"list":
				ui.toggle_list()
			"detail":
				_select("G1")
			"board":
				GameTime.jump_to(8, 5)
				_on_stop_station_click("北京南", "jinghu_hsr", "bjn", 0)
			"checkin":
				Meta.checkins = {
					"南京南": {"t": 25200.0, "n": 1},
					"上海虹桥": {"t": 28800.0, "n": 2},
					"沧州西": {"t": 32400.0, "n": 1}
				}
				cam.position = DB.line("jinghu_hsr")["stations"]["bjn"]["pos"]
				cam.zoom = Vector2(0.03, 0.03)
			"trainfocus":
				GameTime.jump_to(10, 0)
				Meta.set_focus_train("G1")
				_fit_train_route("G1")
			"linefocus":
				Meta.set_focus_line("hukun_hsr")
			"airap":
				Meta.set_aviation(true)
				ui.airport_card.show_airport("CTU")
			"airfl":
				var act: Array = FlightSim.active_flights(GameTime.t)
				if not act.is_empty():
					var fidx: int = act[act.size() / 2]
					_on_flight_click(fidx)
					_locate_flight(fidx)
					cam.zoom = Vector2(0.006, 0.006)
			"yard":
				if DB._name_pos.has("成都南"):
					ui.open_yard_view("成都南", DB._name_pos["成都南"])
			"book":
				Meta.checkins = {
					"南京南": {"t": 25200.0, "n": 1},
					"上海虹桥": {"t": 28800.0, "n": 2},
					"沧州西": {"t": 32400.0, "n": 1},
					"济南西": {"t": 36000.0, "n": 1}
				}
				ui.toggle_checkin_book()
	if _shot_frame == 30 and _shot_mode == "detail":
		# 状态已按新时刻重算，再定位与放大
		_locate("G1")
		cam.zoom = Vector2(0.02, 0.02)
	if _shot_frame >= 50:
		var img := get_viewport().get_texture().get_image()
		img.save_png(OS.get_environment("SHOT_PATH"))
		print("SHOT saved: ", OS.get_environment("SHOT_PATH"))
		_shot_frame = -1
		get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Meta.save()


func _process(delta: float) -> void:
	_shot_tick()

	label_layer.selected = selected
	label_layer.hover = trains_layer.hover
	label_layer.aviation_on = Meta.aviation_on and FlightSim.ready_ok
	label_layer.flight_selected = flights_layer.selected
	label_layer.flight_hover = flights_layer.hover
	label_layer.flight_states = flights_layer._states      # 引用共享，避免重复解算
	label_layer.flight_airborne = flights_layer._airborne
	flights_layer.force_idx = follow_flight if follow_flight >= 0 else flights_layer.selected

	if follow_flight >= 0:
		_flight_follow_tick()

	_station_accum += delta
	if _station_accum > 0.5:
		_station_accum = 0.0
		var ck0 := Time.get_ticks_usec()
		PerfProbe.lap("checkin", 0)
		if Meta.aviation_on:
			# 航空视图：铁路打卡收起，只做机场到访（成就）
			ui.set_checkin_target("", false)
			for iata in FlightSim.airports:
				var ap: Dictionary = FlightSim.airports[iata]
				if (ap["pos"] as Vector2).distance_to(cam.position) < 15000.0:
					Meta.visit_airport(str(iata))
		else:
			var checkin_target := ""
			var checkin_best := 3000.0
			for line_id in DB.line_order:
				var line: Dictionary = DB.lines[line_id]
				for sid in line["order"]:
					var d: float = cam.position.distance_to(line["stations"][sid]["pos"])
					if d < 7000.0:
						Meta.visit_station(sid)
					if d < checkin_best:
						checkin_best = d
						checkin_target = DB.station_name(line_id, sid)
			ui.set_checkin_target(checkin_target, Meta.checkins.has(checkin_target))

	if follow_code != "":
		_follow_tick()
	else:
		ui.set_follow_pill("")

	_save_accum += delta
	if _save_accum > 30.0:
		_save_accum = 0.0
		Meta.save()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				ui.toggle_list()
			KEY_F:
				if follow_flight >= 0:
					_toggle_flight_follow(follow_flight)
				elif selected != "":
					_toggle_follow(selected)
			KEY_F8:
				Meta.set_aviation(not Meta.aviation_on)
			KEY_ESCAPE:
				if Meta.focus_active():
					Meta.clear_focus()
				elif ui.any_overlay_open():
					ui.close_overlays()
				elif ui.flight_card.visible or ui.airport_card.visible:
					ui.close_flight_cards()
				elif follow_flight >= 0:
					_end_flight_follow()
				elif follow_code != "":
					_end_follow(false)
				elif selected != "":
					_select("")
				elif Meta.spot_mode:
					Meta.set_spot_mode(false)
			KEY_F1:
				ui.toggle_help()
			KEY_G:
				ui.toggle_diagram()
			KEY_SPACE:
				GameTime.toggle_pause()
			KEY_P:
				Meta.toggle_spot_mode()
			KEY_EQUAL, KEY_KP_ADD:
				cam.zoom_step(1.3)
			KEY_MINUS, KEY_KP_SUBTRACT:
				cam.zoom_step(1.0 / 1.3)
			KEY_D:
				ui.toggle_dex()
			KEY_J:
				ui.toggle_checkin_book()
			KEY_A:
				ui.toggle_ach()


# ---------- 选择与观测 ----------

func _on_map_click(world_pos: Vector2) -> void:
	if Meta.spot_mode:
		Meta.place_spot(world_pos)
		return
	# 视图互斥：航空视图只点飞机/机场；铁路视图只点列车/车站/线路
	if Meta.aviation_on:
		if not FlightSim.ready_ok:
			return
		var fidx: int = flights_layer.pick(world_pos, cam.zoom.x)
		if fidx >= 0:
			_on_flight_click(fidx)
			return
		var ap: String = flights_layer.pick_airport(world_pos, cam.zoom.x)
		if ap != "":
			_on_airport_click(ap)
		return
	var code: String = trains_layer.pick(world_pos, cam.zoom.x)
	if code != "":
		_select(code)
	else:
		_pick_station(world_pos)


# ---------- 航空 ----------

func _on_flight_click(idx: int) -> void:
	flights_layer.selected = idx
	ui.airport_card.hide()
	ui.detail.hide()
	ui.flight_card.show_flight(idx)
	Meta.observe_flight(str(FlightSim.flights[idx]["id"]))


func _on_airport_click(iata: String) -> void:
	flights_layer.selected = -1
	ui.flight_card.hide()
	ui.detail.hide()
	ui.airport_card.show_airport(iata)


func _on_flight_pick(idx: int) -> void:
	_on_flight_click(idx)
	_locate_flight(idx)


func _toggle_flight_follow(idx: int) -> void:
	if idx < 0 or idx >= FlightSim.flights.size():
		return
	if follow_flight == idx:
		_end_flight_follow()
		return
	_end_flight_follow()
	follow_flight = idx
	cam.follow_code = ""
	ui.flight_card.set_following(true)


func _end_flight_follow() -> void:
	if follow_flight < 0:
		return
	follow_flight = -1
	ui.flight_card.set_following(false)
	ui.set_follow_pill("")


func _locate_flight(idx: int) -> void:
	var st: Dictionary = FlightSim.state_for(idx, GameTime.t)
	cam.follow_code = ""
	cam.position = st["pos"]


func _flight_follow_tick() -> void:
	var idx := follow_flight
	if idx >= FlightSim.flights.size():
		_end_flight_follow()
		return
	var fl: Dictionary = FlightSim.flights[idx]
	var st: Dictionary = FlightSim.state_for(idx, GameTime.t)
	var ph: String = str(st["phase"])
	if ph == "done":
		ui.show_toast("🛬 %s 已到达 %s" % [str(fl["id"]), FlightSim.airports[fl["to"]]["name"]])
		Meta.report_follow_flight_done()
		_end_flight_follow()
		return
	if ph == "climb" or ph == "cruise" or ph == "descend":
		cam.position = st["pos"]
		ui.set_follow_pill("正在跟随 %s · %s · 高度 %d km · [Esc] 退出" % [
			str(fl["id"]), _phase_cn(ph), int(float(st["alt"]) / 1000.0)])
	else:
		ui.set_follow_pill("跟随 %s · 地面滑行/等待" % str(fl["id"]))


func _phase_cn(ph: String) -> String:
	match ph:
		"climb":
			return "爬升"
		"cruise":
			return "巡航"
		"descend":
			return "下降"
		_:
			return "地面"


# 详情卡停站名点击 -> 站点信息卡
func _on_stop_station_click(sname: String, line_id: String, sid: String, km: int) -> void:
	var line_names: Array = []
	for lid in DB.line_order:
		var l2: Dictionary = DB.lines[lid]
		for sid2 in l2["order"]:
			if l2["stations"][sid2]["name"] == sname:
				line_names.append(str(l2["short"]))
				break
	var stops_n := 0
	for tr in DB.trains:
		for stop in tr["stops"]:
			if str(stop.get("name", "")) == sname:
				stops_n += 1
				break
	var major := false
	if line_id != "" and DB.line(line_id)["stations"].has(sid):
		major = bool(DB.line(line_id)["stations"][sid]["major"])
	ui.station_card.show_station(sname, line_names, km, stops_n, major)


# 点击空白处：拾取附近车站显示信息卡
func _pick_station(world_pos: Vector2) -> void:
	var radius := 26.0 / cam.zoom.x
	var best_d := radius
	var best_line := ""
	var best_sid := ""
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		for sid in line["order"]:
			var d: float = world_pos.distance_to(line["stations"][sid]["pos"])
			if d < best_d:
				best_d = d
				best_line = line_id
				best_sid = sid
	if best_sid == "":
		var lid: String = DB.nearest_line(world_pos, 22.0 / cam.zoom.x)
		if lid != "":
			# 点击线路：直接专注展示该线（地图放大+隐藏其他线），并打开线路页面
			Meta.set_focus_line(lid if Meta.focus_line != lid else "")
			if Meta.focus_line != "":
				var line: Dictionary = DB.line(lid)
				cam.follow_code = ""
				cam.position = line["center"]
				cam.zoom = Vector2(line["fit_zoom"], line["fit_zoom"])
			ui.line_screen.open(lid)
		return
	var line: Dictionary = DB.lines[best_line]
	var st: Dictionary = line["stations"][best_sid]
	var sname: String = st["name"]
	# 所属线路（按站名跨线汇总）
	var line_names: Array = []
	for lid in DB.line_order:
		var l2: Dictionary = DB.lines[lid]
		for sid2 in l2["order"]:
			if l2["stations"][sid2]["name"] == sname:
				line_names.append(str(l2["short"]))
				break
	# 日均停靠车次（按站名）
	var stops_n := 0
	for tr in DB.trains:
		for stop in tr["stops"]:
			if str(stop.get("name", "")) == sname:
				stops_n += 1
				break
	ui.station_card.show_station(sname, line_names, int(st["km"]), stops_n,
			bool(st["major"]))


func _on_map_right_click(world_pos: Vector2) -> void:
	if Meta.spot_mode:
		Meta.remove_nearest_spot(world_pos, 60.0 / cam.zoom.x)


func _on_train_clicked(code: String) -> void:
	# 由相机统一分发点击；此信号仅保留接口
	_select(code)


func _on_train_search_pick(code: String) -> void:
	_select(code)
	_locate(code)


func _on_line_screen_pick(code: String) -> void:
	ui.line_screen.visible = false
	_select(code)
	_locate(code)


func _on_focus_changed() -> void:
	if Meta.focus_line == "":
		return
	var line: Dictionary = DB.line(Meta.focus_line)
	cam.follow_code = ""
	cam.position = line["center"]
	cam.zoom = Vector2(line["fit_zoom"], line["fit_zoom"])


func _on_diagram_pick(code: String) -> void:
	# 运行图上点选：不移动相机，仅选中（相机仍在地图视图）
	_select(code)


func _on_list_select(code: String) -> void:
	_select(code)
	_locate(code)


func _select(code: String) -> void:
	selected = code
	trains_layer.selected = code
	if code != "":
		ui.close_flight_cards()
	if Meta.focus_train != "" and code != "" and code != Meta.focus_train:
		Meta.set_focus_train(code)
		_fit_train_route(code)
		ui.sync_focus_pill()
	ui.detail.set_train(code)
	ui.diagram.set_selected(code)
	if code == "":
		return
	var st: Dictionary = Simulation.states.get(code, {})
	var status := str(st.get("status", "off"))
	if status == "run" or status == "stop" or status == "wait":
		var line_id: String = str(st.get("line", DB.line_order[0]))
		var sid: String = DB.nearest_station(line_id, st.get("pos", DB.map_center))
		Meta.observe(code, str(st.get("type", "")), GameTime.t, DB.station_name(line_id, sid))


func _enter_train_focus(code: String) -> void:
	Meta.set_focus_train(code)
	_fit_train_route(code)
	ui.sync_focus_pill()


func _fit_train_route(code: String) -> void:
	if not DB.train_by_code.has(code):
		return
	var mn := Vector2.INF
	var mx := -Vector2.INF
	for stop in DB.train_by_code[code]["stops"]:
		var lid: String = str(stop.get("line", ""))
		var sid: String = str(stop.get("sid", ""))
		if lid == "" or not DB.lines.has(lid):
			continue
		var line: Dictionary = DB.lines[lid]
		if not line["stations"].has(sid):
			continue
		var pos: Vector2 = line["stations"][sid]["pos"]
		mn = mn.min(pos)
		mx = mx.max(pos)
	if mn == Vector2.INF:
		return
	cam.follow_code = ""
	cam.position = (mn + mx) * 0.5
	var size: Vector2 = mx - mn
	var z: float = minf(1500.0 / maxf(size.x, 800.0), 830.0 / maxf(size.y, 600.0))
	z = clampf(z, 0.0008, 0.08)
	cam.zoom = Vector2(z, z)


func _on_line_focus_camera() -> void:
	# 线路专注变更时统一飞至该线中心（搜索/点击/切换入口都走这里）
	if Meta.focus_line == "" or Meta.focus_train != "":
		return
	var line: Dictionary = DB.line(Meta.focus_line)
	cam.follow_code = ""
	cam.position = line["center"]
	cam.zoom = Vector2(line["fit_zoom"], line["fit_zoom"])


# ---------- 视图分离：铁路 / 航空 ----------

var _cam_rail := {"has": false, "pos": Vector2.ZERO, "z": 0.0}
var _cam_air := {"has": false, "pos": Vector2.ZERO, "z": 0.0}


func _on_aviation_view_switched() -> void:
	# 双视图各自记忆相机：切换时保存当前、恢复目标视图上次的视野
	var cur := {"has": true, "pos": cam.position, "z": cam.zoom.x}
	if Meta.aviation_on:
		_cam_rail = cur
		# 铁路专属状态随视图收起
		if Meta.focus_active():
			Meta.clear_focus()
			ui.sync_focus_pill()
		if follow_code != "":
			_end_follow(false)
		_select("")
		if _cam_air["has"]:
			cam.follow_code = ""
			cam.position = _cam_air["pos"]
			cam.zoom = Vector2(_cam_air["z"], _cam_air["z"])
		else:
			cam.follow_code = ""
			cam.position = DB.map_center
			cam.zoom = Vector2(DB.fit_zoom * 1.02, DB.fit_zoom * 1.02)
	else:
		_cam_air = cur
		if follow_flight >= 0:
			_end_flight_follow()
		ui.close_flight_cards()
		flights_layer.selected = -1
		if _cam_rail["has"]:
			cam.follow_code = ""
			cam.position = _cam_rail["pos"]
			cam.zoom = Vector2(_cam_rail["z"], _cam_rail["z"])


func _locate(code: String) -> void:
	var st: Dictionary = Simulation.states.get(code, {})
	if st.has("pos"):
		cam.follow_code = ""
		cam.position = st["pos"]


# ---------- 跟随 ----------

func _toggle_follow(code: String) -> void:
	if follow_code == code:
		_end_follow(false)
	else:
		_start_follow(code)


func _start_follow(code: String) -> void:
	if not DB.train_by_code.has(code):
		return
	# 结束旧的跟随并结算
	if follow_code != "":
		_end_follow(false)
	follow_code = code
	_f_reported = false
	_f_last_pos = Vector2(NAN, NAN)
	_f_dist = 0.0
	trains_layer.trail.clear()
	cam.follow_code = code
	ui.detail.following = true

	var st: Dictionary = Simulation.states.get(code, {})
	var status := str(st.get("status", "off"))
	_f_started_at_departure = status == "wait" or (status == "run" and float(st.get("rel", 1.0e9)) < 120.0)
	var train: Dictionary = DB.train_by_code[code]
	_f_full_line = (train["from"] == "北京南" or train["from"] == "上海虹桥") \
			and (train["to"] == "北京南" or train["to"] == "上海虹桥") \
			and not bool(train.get("off_map", false))
	_cross_ready = true


func _end_follow(completed: bool) -> void:
	var was := follow_code
	if was == "":
		return
	follow_code = ""
	cam.follow_code = ""
	ui.detail.following = false
	ui.set_follow_pill("")
	if not _f_reported:
		_f_reported = true
		var st: Dictionary = Simulation.states.get(was, {})
		var arrived: bool = completed and str(st.get("status", "")) == "done"
		Meta.report_follow_session(was, _f_dist / 1000.0, arrived, _f_full_line, _f_started_at_departure)


func _follow_tick() -> void:
	var st: Dictionary = Simulation.states.get(follow_code, {})
	var status := str(st.get("status", "off"))
	if status != "run" and status != "stop" and status != "wait":
		_end_follow(true)
		return
	var pos_now: Vector2 = st.get("pos", Vector2.ZERO)
	if is_nan(_f_last_pos.x):
		_f_last_pos = pos_now
	elif _f_last_pos.distance_to(pos_now) < 30000.0:
		_f_dist += _f_last_pos.distance_to(pos_now)
	_f_last_pos = pos_now
	if trains_layer.trail.is_empty() or trains_layer.trail[-1].distance_to(pos_now) > 500.0:
		trains_layer.trail.append(pos_now)
		if trains_layer.trail.size() > 80:
			trains_layer.trail.pop_front()
	ui.set_follow_pill("正在跟随 %s · 已跟随 %d km · [Esc] 退出" % [follow_code, int(_f_dist / 1000.0)])

	# 对向交会检测（每次跟随会话最多上报一次）
	if _cross_ready:
		for oc in Simulation.states:
			if oc == follow_code:
				continue
			var ost: Dictionary = Simulation.states[oc]
			if str(ost.get("status", "")) == "run" and str(ost.get("dir", "")) != str(st.get("dir", "")) \
					and (ost["pos"] as Vector2).distance_to(st["pos"] as Vector2) < 2500.0:
				Meta.report_cross_meet()
				_cross_ready = false
				break

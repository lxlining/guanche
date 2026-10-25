# 主场景：组装地图/列车/机位/相机/UI，处理点选、跟随、快捷键与成就联动。
extends Node2D

const MapRenderer := preload("res://src/map/map_renderer.gd")
const CameraController := preload("res://src/map/camera_controller.gd")
const TrainLayer := preload("res://src/map/train_layer.gd")
const SpotLayer := preload("res://src/map/spot_layer.gd")
const LabelLayer := preload("res://src/map/label_layer.gd")
const MainUI := preload("res://src/ui/main_ui.gd")

var cam: Camera2D
var trains_layer: Node2D
var label_layer: CanvasLayer
var ui: CanvasLayer

var selected := ""

var follow_code := ""
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
	var spots := SpotLayer.new()
	spots.name = "SpotLayer"
	add_child(spots)
	trains_layer = TrainLayer.new()
	trains_layer.name = "TrainLayer"
	add_child(trains_layer)
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
	ui.train_list.connect("train_selected", _on_list_select)
	ui.detail.connect("follow_requested", _toggle_follow)
	ui.detail.connect("locate_requested", _locate)
	ui.detail.connect("closed", func(): _select(""))
	cam.connect("map_clicked", _on_map_click)
	cam.connect("map_right_clicked", _on_map_right_click)
	ui.diagram.connect("train_picked", _on_diagram_pick)

	if Meta.is_fresh:
		ui.help_panel.visible = true

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
		match _shot_mode:
			"help":
				ui.help_panel.visible = true
			"dex":
				ui.toggle_dex()
			"ach":
				ui.toggle_ach()
			_:
				ui.close_overlays()
	if _shot_frame == 8 and _shot_mode == "zoom":
		cam.position = DB.line("jinghu_hsr")["stations"]["jnx"]["pos"]
		cam.zoom = Vector2(0.03, 0.03)
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

	_station_accum += delta
	if _station_accum > 0.5:
		_station_accum = 0.0
		for line_id in DB.line_order:
			var line: Dictionary = DB.lines[line_id]
			for sid in line["order"]:
				if cam.position.distance_to(line["stations"][sid]["pos"]) < 7000.0:
					Meta.visit_station(sid)

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
				if selected != "":
					_toggle_follow(selected)
			KEY_ESCAPE:
				if ui.any_overlay_open():
					ui.close_overlays()
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
			KEY_D:
				ui.toggle_dex()
			KEY_A:
				ui.toggle_ach()


# ---------- 选择与观测 ----------

func _on_map_click(world_pos: Vector2) -> void:
	if Meta.spot_mode:
		Meta.place_spot(world_pos)
		return
	var code: String = trains_layer.pick(world_pos, cam.zoom.x)
	_select(code)


func _on_map_right_click(world_pos: Vector2) -> void:
	if Meta.spot_mode:
		Meta.remove_nearest_spot(world_pos, 60.0 / cam.zoom.x)


func _on_train_clicked(code: String) -> void:
	# 由相机统一分发点击；此信号仅保留接口
	_select(code)


func _on_diagram_pick(code: String) -> void:
	# 运行图上点选：不移动相机，仅选中（相机仍在地图视图）
	_select(code)


func _on_list_select(code: String) -> void:
	_select(code)
	_locate(code)


func _select(code: String) -> void:
	selected = code
	trains_layer.selected = code
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

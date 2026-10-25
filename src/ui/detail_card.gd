# 列车详情卡：选中列车的实时状态、速度、里程、下一站与全程停站表。
extends PanelContainer

signal follow_requested(code: String)
signal station_info_requested(sname: String, line_id: String, sid: String, km: int)
signal locate_requested(code: String)
signal closed

const UIKit := preload("res://src/ui/ui_kit.gd")
const EmuIllu := preload("res://src/ui/emu_illustration.gd")

var code := ""
var following := false
var illu: Control

var title_label: Label
var badge_label: Label
var route_label: Label
var status_label: Label
var next_label: Label
var meta_label: Label
var stops_box: VBoxContainer
var follow_btn: Button
var _rows: Array = []  # {arr_l, dep_l, arr_s, dep_s, dim_refs}
var _tick := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 14)
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_theme_stylebox_override("panel", UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 14))
	custom_minimum_size = Vector2(400, 0)
	visible = false

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	vb.add_child(head)
	title_label = UIKit.label("G1", 26, Color.WHITE)
	head.add_child(title_label)
	badge_label = UIKit.label("", 12, UIKit.ACCENT2)
	badge_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(badge_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var close_btn := UIKit.button("×", func(): _close())
	close_btn.custom_minimum_size = Vector2(30, 26)
	head.add_child(close_btn)

	route_label = UIKit.label("", 14, UIKit.TEXT)
	vb.add_child(route_label)
	illu = EmuIllu.new()
	vb.add_child(illu)
	status_label = UIKit.label("", 13, UIKit.GOOD)
	vb.add_child(status_label)
	next_label = UIKit.label("", 12, UIKit.DIM)
	vb.add_child(next_label)
	meta_label = UIKit.label("", 12, UIKit.DIM)
	vb.add_child(meta_label)

	vb.add_child(UIKit.vspace(2))
	vb.add_child(UIKit.label("停站时刻", 12, UIKit.DIM))
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 250)
	sc.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	vb.add_child(sc)
	stops_box = VBoxContainer.new()
	stops_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stops_box.add_theme_constant_override("separation", 1)
	sc.add_child(stops_box)

	vb.add_child(UIKit.vspace(4))
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	vb.add_child(btns)
	follow_btn = UIKit.button("跟随 [F]")
	follow_btn.pressed.connect(func(): follow_requested.emit(code))
	btns.add_child(follow_btn)
	btns.add_child(UIKit.button("定位", func(): locate_requested.emit(code)))
	var sp2 := Control.new()
	sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btns.add_child(sp2)
	btns.add_child(UIKit.button("收起", func(): _close()))


func set_train(c: String) -> void:
	code = c
	if c == "" or not DB.train_by_code.has(c):
		visible = false
		return
	visible = true
	var train: Dictionary = DB.train_by_code[c]
	var tt: Dictionary = DB.train_types.get(train["type"], {})
	illu.setup(tt, 46.0)
	var line_short: String = str(DB.line(str(train.get("line", DB.line_order[0])))["short"])
	title_label.text = train["code"]
	badge_label.text = "%s · %s · %s" % [tt.get("name", "?"), tt.get("formation", ""), line_short]
	route_label.text = "%s  →  %s%s" % [train["from"], train["to"],
			"（驶离本线）" if train.get("off_map", false) else ""]
	_build_stops(train)
	_tick_now()


func _open_station_info(sname: String, line_id: String, sid: String, km: int) -> void:
	station_info_requested.emit(sname, line_id, sid, km)


func _close() -> void:
	visible = false
	code = ""
	closed.emit()


func _build_stops(train: Dictionary) -> void:
	for c in stops_box.get_children():
		c.queue_free()
	_rows.clear()
	var tt: Dictionary = DB.train_types.get(train["type"], {})
	for i in range(train["stops"].size()):
		var stop: Dictionary = train["stops"][i]
		if i > 0 and stop.get("line", "") != "" and stop["line"] == train["stops"][i - 1].get("line", ""):
			var order: Array = DB.line(str(stop["line"]))["order"]
			var pass_n := absi(order.find(stop["sid"]) - order.find(train["stops"][i - 1]["sid"])) - 1
			if pass_n > 0:
				var pass_l := UIKit.label("　··· 途中通过 %d 站 ···" % pass_n, 11, Color(0.5, 0.56, 0.66, 0.7))
				stops_box.add_child(pass_l)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var first := i == 0
		var last: bool = i == train["stops"].size() - 1
		# 线路色点（跨线车可看出换线处）
		var stop_line: String = str(stop.get("line", ""))
		var dot_col: Color = DB.line(stop_line)["color"] if stop_line != "" else UIKit.DIM
		var dot := UIKit.label("●", 11, dot_col)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)
		# 站名（可点击 -> 站点信息卡）
		var name_btn := Button.new()
		name_btn.text = str(stop.get("name", stop["sid"]))
		name_btn.flat = true
		name_btn.focus_mode = Control.FOCUS_NONE
		name_btn.add_theme_font_size_override("font_size", 13)
		name_btn.add_theme_color_override("font_color", UIKit.TEXT)
		name_btn.add_theme_color_override("font_hover_color", Color.WHITE)
		name_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		name_btn.custom_minimum_size = Vector2(96, 0)
		var sname: String = str(stop.get("name", stop["sid"]))
		var sline: String = stop_line
		var skm: int = 0
		if sline != "" and DB.line(sline)["stations"].has(stop["sid"]):
			skm = int(DB.line(sline)["stations"][stop["sid"]]["km"])
		name_btn.pressed.connect(_open_station_info.bind(sname, sline, stop["sid"], skm))
		row.add_child(name_btn)
		var arr_l := UIKit.label("——" if first else GameTime.fmt_hhmm_abs(stop["arr_s"]), 13, UIKit.DIM)
		arr_l.custom_minimum_size = Vector2(64, 0)
		row.add_child(arr_l)
		var dep_l := UIKit.label("——" if last else GameTime.fmt_hhmm_abs(stop["dep_s"]) + " 发", 13, UIKit.DIM)
		dep_l.custom_minimum_size = Vector2(72, 0)
		row.add_child(dep_l)
		# 停靠时长（中间站）
		var dwell := "始发" if first else ("终到" if last else "")
		if dwell == "" and stop["dep_s"] > stop["arr_s"]:
			dwell = "停 %d 分" % int((stop["dep_s"] - stop["arr_s"]) / 60.0)
		var note_l := UIKit.label(dwell, 11, UIKit.WARN)
		note_l.custom_minimum_size = Vector2(52, 0)
		row.add_child(note_l)
		# 换线标记（跨线车：下一停靠站已属另一条线路）
		if not last:
			var next_line: String = str(train["stops"][i + 1].get("line", ""))
			if next_line != "" and next_line != stop_line:
				var sw := UIKit.label("→ 换 %s" % DB.line(next_line)["short"], 11,
						DB.line(next_line)["color"])
				sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				row.add_child(sw)
		stops_box.add_child(row)
		_rows.append({"arr_l": arr_l, "dep_l": dep_l, "note_l": note_l,
				"arr_s": stop["arr_rel"], "dep_s": stop["dep_rel"], "row": row})


func _process(delta: float) -> void:
	if not visible or code == "":
		return
	_tick += delta
	if _tick > 0.2:
		_tick = 0.0
		_tick_now()


func _tick_now() -> void:
	if not DB.train_by_code.has(code):
		return
	var train: Dictionary = DB.train_by_code[code]
	var tt: Dictionary = DB.train_types.get(train["type"], {})
	var st: Dictionary = Simulation.states.get(code, {})
	var status := str(st.get("status", "off"))
	var start_t: float = train["stops"][0]["dep_s"]

	match status:
		"off":
			status_label.text = "未上线 · %s 从 %s 发车" % [GameTime.fmt_hhmm_abs(start_t), train["from"]]
			status_label.add_theme_color_override("font_color", UIKit.DIM)
			next_label.text = ""
		"wait":
			status_label.text = "始发待发 · %s 发车" % GameTime.fmt_hhmm_abs(start_t)
			status_label.add_theme_color_override("font_color", UIKit.WARN)
			next_label.text = "下一站：%s" % str(train["stops"][1].get("name", ""))
		"run":
			status_label.text = "在途 · K%d · %d km/h" % [int(st.get("km", 0)), int(st.get("speed_kmh", 0.0))]
			status_label.add_theme_color_override("font_color", UIKit.GOOD)
			var nsid: String = st.get("next_sid", "")
			if nsid != "":
				next_label.text = "下一站：%s · %s 到" % [str(st.get("next_name", nsid)), GameTime.fmt_hhmm_abs(st.get("next_arr_s", -1.0))]
		"stop":
			var cur_i := int(st.get("stop_idx", 0))
			status_label.text = "停站 %s" % str(train["stops"][cur_i].get("name", ""))
			status_label.add_theme_color_override("font_color", UIKit.ACCENT2)
			if cur_i + 1 < train["stops"].size():
				next_label.text = "%s 发车 · 下一站 %s" % [
					GameTime.fmt_hhmm_abs(train["stops"][cur_i]["dep_s"]),
					str(train["stops"][cur_i + 1].get("name", ""))]
		"done":
			status_label.text = "已终到 %s" % train["to"]
			status_label.add_theme_color_override("font_color", UIKit.DIM)
			next_label.text = ""

	var family: String = str(tt.get("family", ""))
	var spot_cnt: int = int(Meta.spotted.get(code, {}).get("count", 0))
	meta_label.text = "%s · 最高 %d km/h · 观测 %s" % [family, int(tt.get("speed", 350)),
			("%d 次" % spot_cnt) if spot_cnt > 0 else "未收录"]

	var rel := float(st.get("rel", -1.0))
	var active := status == "run" or status == "stop" or status == "wait"
	for r in _rows:
		var arr_l: Label = r["arr_l"]
		var dep_l: Label = r["dep_l"]
		var note_l: Label = r["note_l"]
		if not active:
			arr_l.add_theme_color_override("font_color", UIKit.DIM)
			dep_l.add_theme_color_override("font_color", UIKit.DIM)
			continue
		if rel >= float(r["dep_s"]):
			arr_l.add_theme_color_override("font_color", Color(0.45, 0.5, 0.6))
			dep_l.add_theme_color_override("font_color", Color(0.45, 0.5, 0.6))
		elif rel >= float(r["arr_s"]):
			arr_l.add_theme_color_override("font_color", UIKit.ACCENT2)
			dep_l.add_theme_color_override("font_color", UIKit.ACCENT2)
			note_l.text = "当前停靠"
		else:
			arr_l.add_theme_color_override("font_color", UIKit.TEXT)
			dep_l.add_theme_color_override("font_color", UIKit.TEXT)

	follow_btn.text = "跟随中 [Esc]" if following else "跟随 [F]"

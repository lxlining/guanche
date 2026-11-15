# 机场信息卡：机场概览（枢纽/航线数/日均起降/通达 Top）+ 出发大屏。
# 出发行按距当前时刻的起飞间隔排序、状态列就地刷新，点击行选中该航班。
extends PanelContainer

const UIKit := preload("res://src/ui/ui_kit.gd")

signal flight_picked(idx: int)

const MAX_ROWS := 14

var title_label: Label
var sub_label: Label
var stat_label: Label
var dest_label: Label
var board_title: Label
var board_clock: Label
var board_rows: VBoxContainer
var cur_iata := ""
var _board_hour := -1
var _dep_idx: Array = []
var _arr_idx: Array = []
var _rows_meta: Array = []   # [{idx, status: Label}]
var _accum := 0.0
var _board_mode := "dep"     # dep=出发 / arr=到港


func _ready() -> void:
	add_theme_stylebox_override("panel", UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 14))
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	grow_vertical = Control.GROW_DIRECTION_BOTH
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	custom_minimum_size = Vector2(370, 0)
	visible = false

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	title_label = UIKit.label("机场", 20, Color.WHITE)
	head.add_child(title_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var close_btn := UIKit.button("×", func(): hide())
	close_btn.custom_minimum_size = Vector2(30, 26)
	head.add_child(close_btn)
	sub_label = UIKit.label("", 12, UIKit.ACCENT2)
	vb.add_child(sub_label)
	stat_label = UIKit.label("", 12, UIKit.TEXT)
	vb.add_child(stat_label)
	dest_label = UIKit.label("", 11, UIKit.DIM)
	dest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dest_label.custom_minimum_size = Vector2(344, 0)
	vb.add_child(dest_label)
	vb.add_child(UIKit.hspace(4))
	var bhead := HBoxContainer.new()
	bhead.add_theme_constant_override("separation", 6)
	vb.add_child(bhead)
	board_title = UIKit.label("🛫 出发大屏", 14, Color.WHITE)
	bhead.add_child(board_title)
	var dep_btn := UIKit.button("出发", func(): _set_board_mode("dep"))
	dep_btn.custom_minimum_size = Vector2(48, 24)
	bhead.add_child(dep_btn)
	var arr_btn := UIKit.button("到港", func(): _set_board_mode("arr"))
	arr_btn.custom_minimum_size = Vector2(48, 24)
	bhead.add_child(arr_btn)
	board_clock = UIKit.label("", 12, UIKit.ACCENT2)
	board_clock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bhead.add_child(board_clock)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(348, 260)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	board_rows = VBoxContainer.new()
	board_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_rows.add_theme_constant_override("separation", 1)
	scroll.add_child(board_rows)


func show_airport(iata: String) -> void:
	if not FlightSim.airports.has(iata):
		return
	cur_iata = iata
	visible = true
	_board_hour = -1
	_reload()
	_rebuild_board()


func _reload() -> void:
	var ap: Dictionary = FlightSim.airports[cur_iata]
	title_label.text = "%s (%s)%s" % [str(ap["name"]), cur_iata,
			"　●枢纽" if int(ap["major"]) == 1 else ""]
	sub_label.text = "%s · 航线 %d 条" % [str(ap["city"]), int(ap["routes_n"])]
	stat_label.text = "日均进出港约 %d 班" % int(ap["dep_arr"])
	var dests: Array = FlightSim.airport_top_dest(cur_iata, 8)
	var parts: Array = []
	for d in dests:
		parts.append("%s(%d)" % [FlightSim.airports[str(d[0])]["city"], d[1]])
	dest_label.text = ("通达 Top：%s" % " · ".join(parts)) if not parts.is_empty() else ""


func _process(delta: float) -> void:
	if not visible or cur_iata == "":
		return
	_accum += delta
	if _accum < 1.0:
		return
	_accum = 0.0
	var h := int(fposmod(GameTime.t, 86400.0) / 3600.0)
	if h != _board_hour:
		_rebuild_board()
	else:
		_refresh_statuses()


func _set_board_mode(mode: String) -> void:
	if _board_mode == mode:
		return
	_board_mode = mode
	board_title.text = "🛫 出发大屏" if mode == "dep" else "🛬 到港大屏"
	_rebuild_board()


func _rebuild_board() -> void:
	_board_hour = int(fposmod(GameTime.t, 86400.0) / 3600.0)
	var t := GameTime.t
	_rows_meta = []
	for c in board_rows.get_children():
		c.queue_free()
	if _board_mode == "dep":
		_dep_idx = FlightSim.airport_departures(cur_iata, t)
		board_title.text = "🛫 出发大屏 · 本日 %d 班" % _dep_idx.size()
		for idx in _dep_idx.slice(0, MAX_ROWS):
			var fl: Dictionary = FlightSim.flights[idx]
			_add_row(idx, GameTime.fmt_hhmm_abs(float(fl["dep"])),
					"→ %s" % str(FlightSim.airports[fl["to"]]["city"]))
	else:
		_arr_idx = FlightSim.airport_arrivals(cur_iata, t)
		board_title.text = "🛬 到港大屏 · 本日 %d 班" % _arr_idx.size()
		for idx in _arr_idx.slice(0, MAX_ROWS):
			var fl: Dictionary = FlightSim.flights[idx]
			var land: float = float(fl["dep"]) + float(fl["dur"])
			_add_row(idx, GameTime.fmt_hhmm_abs(land),
					"← %s" % str(FlightSim.airports[fl["from"]]["city"]))
	_refresh_statuses()


func _add_row(idx: int, time_txt: String, dir_txt: String) -> void:
	var fl: Dictionary = FlightSim.flights[idx]
	var row := Button.new()
	row.custom_minimum_size = Vector2(344, 24)
	row.add_theme_stylebox_override("normal", UIKit.flat(Color(1, 1, 1, 0.03), 5))
	row.add_theme_stylebox_override("hover", UIKit.flat(Color(1, 1, 1, 0.08), 5))
	row.add_theme_stylebox_override("pressed", UIKit.flat(Color(1, 1, 1, 0.12), 5))
	row.pressed.connect(func(): flight_picked.emit(idx))
	var hb := HBoxContainer.new()
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.add_theme_constant_override("separation", 6)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hb)
	var time_l := UIKit.label(time_txt, 12, UIKit.TEXT)
	time_l.custom_minimum_size = Vector2(56, 0)
	time_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(time_l)
	var col := Color(str(fl["al_color"]))
	var id_l := UIKit.label(str(fl["id"]), 12, col.lightened(0.25))
	id_l.custom_minimum_size = Vector2(76, 0)
	id_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(id_l)
	var to_l := UIKit.label(dir_txt, 12, UIKit.DIM)
	to_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	to_l.clip_text = true
	to_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(to_l)
	var status_l := UIKit.label("", 11, UIKit.DIM)
	status_l.custom_minimum_size = Vector2(64, 0)
	status_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(status_l)
	board_rows.add_child(row)
	_rows_meta.append({"idx": idx, "status": status_l})


func _refresh_statuses() -> void:
	var t := GameTime.t
	board_clock.text = "现在 " + GameTime.time_string()
	for m in _rows_meta:
		var fl: Dictionary = FlightSim.flights[m["idx"]]
		var text := ""
		var col := UIKit.DIM
		if _board_mode == "dep":
			var gap := fposmod(float(fl["dep"]) - t, 86400.0)
			var el := fposmod(t - float(fl["dep"]), 86400.0)
			if el < float(fl["dur"]):
				text = "已起飞"
				col = Color("67c987")
			elif gap <= 600.0:
				text = "登机"
				col = Color("ffb454")
			elif gap <= 1800.0:
				text = "即将起飞"
				col = Color("ffb454")
			else:
				text = "值机"
		else:
			var land: float = float(fl["dep"]) + float(fl["dur"])
			var gap := fposmod(land - t, 86400.0)
			var since := fposmod(t - land, 86400.0)
			var el := fposmod(t - float(fl["dep"]), 86400.0)
			if since < 900.0:
				text = "已降落"
				col = Color("67c987")
			elif gap <= 600.0:
				text = "即将降落"
				col = Color("ffb454")
			elif el < float(fl["dur"]):
				text = "在途"
				col = UIKit.ACCENT2
			else:
				text = "计划"
		var sl: Label = m["status"]
		sl.text = text
		sl.add_theme_color_override("font_color", col)

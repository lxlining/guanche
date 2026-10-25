# 线路页面（全屏）：左侧线路信息栏（概况 + 车站序列），
# 右侧车次区（顶部大搜索框 + 全部车次列表）。点击车次联动地图与详情卡。
extends Control

signal code_picked(code: String)

const UIKit := preload("res://src/ui/ui_kit.gd")

var line_id := ""
var search: LineEdit
var trains_box: VBoxContainer
var stations_box: VBoxContainer
var title_label: Label
var sub_label: Label
var stats_grid: GridContainer
var count_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.05, 0.88)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var main_vb := VBoxContainer.new()
	main_vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 40)
	main_vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	main_vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(main_vb)

	# 顶栏：标题 + 关闭
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	main_vb.add_child(top)
	title_label = UIKit.label("线路", 26, Color.WHITE)
	top.add_child(title_label)
	sub_label = UIKit.label("", 13, UIKit.DIM)
	sub_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(sub_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	var close_btn := UIKit.button("返回地图 [Esc]", func(): visible = false)
	top.add_child(close_btn)

	# 内容区：左栏（信息+车站） / 右栏（搜索+车次）
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 16)
	main_vb.add_child(cols)

	# —— 左栏 ——
	var left_panel := UIKit.panel_container(UIKit.flat(UIKit.CARD, 12, UIKit.BORDER, 1, 14))
	left_panel.custom_minimum_size = Vector2(340, 0)
	left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_child(left_panel)
	var lvb := VBoxContainer.new()
	lvb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lvb.add_theme_constant_override("separation", 8)
	left_panel.add_child(lvb)

	lvb.add_child(UIKit.label("线路概况", 14, UIKit.ACCENT2))
	stats_grid = GridContainer.new()
	stats_grid.columns = 2
	stats_grid.add_theme_constant_override("h_separation", 12)
	stats_grid.add_theme_constant_override("v_separation", 4)
	lvb.add_child(stats_grid)

	lvb.add_child(UIKit.vspace(4))
	lvb.add_child(UIKit.label("车站序列", 14, UIKit.ACCENT2))
	var lsc := ScrollContainer.new()
	lsc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lsc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lvb.add_child(lsc)
	stations_box = VBoxContainer.new()
	stations_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stations_box.add_theme_constant_override("separation", 2)
	lsc.add_child(stations_box)

	# —— 右栏 ——
	var right_vb := VBoxContainer.new()
	right_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vb.add_theme_constant_override("separation", 8)
	cols.add_child(right_vb)

	# 搜索框（显眼置顶）
	var search_wrap := UIKit.panel_container(UIKit.flat(Color("1a2332"), 10, UIKit.ACCENT, 1, 8))
	right_vb.add_child(search_wrap)
	var shb := HBoxContainer.new()
	shb.add_theme_constant_override("separation", 10)
	shb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_wrap.add_child(shb)
	var icon := UIKit.label("🔍", 16, UIKit.ACCENT2)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	shb.add_child(icon)
	search = LineEdit.new()
	search.placeholder_text = "搜索本线路车次：输入车次号（G1 / D901）或始发终到站名"
	search.clear_button_enabled = true
	search.custom_minimum_size = Vector2(0, 34)
	search.add_theme_font_size_override("font_size", 15)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(func(_t: String): _rebuild())
	shb.add_child(search)

	count_label = UIKit.label("", 12, UIKit.ACCENT2)
	right_vb.add_child(count_label)

	var rsc := ScrollContainer.new()
	rsc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rsc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vb.add_child(rsc)
	trains_box = VBoxContainer.new()
	trains_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trains_box.add_theme_constant_override("separation", 3)
	rsc.add_child(trains_box)


func open(id: String) -> void:
	line_id = id
	visible = true
	_refresh()
	search.grab_focus()


func _refresh() -> void:
	var line: Dictionary = DB.line(line_id)
	title_label.text = str(line["name"])
	var cls_name: String = {"hsr350": "高铁 350km/h", "hsr250": "高铁 200-250km/h",
			"intercity": "城际铁路", "conventional": "普速铁路",
			"freight": "货运专线"}.get(DB.line_class(line_id), "铁路")
	sub_label.text = cls_name
	for c in stats_grid.get_children():
		c.queue_free()
	var trains := _line_trains()
	var info := [
		["起讫", "%s — %s" % [line["from"], line["to"]]],
		["营业里程", "%.0f km" % (line["total_len_m"] / 1000.0)],
		["车站数", "%d 座" % line["order"].size()],
		["日均车次", "%d 趟" % trains.size()],
	]
	for kv in info:
		stats_grid.add_child(UIKit.label(str(kv[0]), 12, UIKit.DIM))
		stats_grid.add_child(UIKit.label(str(kv[1]), 13, UIKit.TEXT))
	_rebuild()
	_build_stations()


func _line_trains() -> Array:
	var out: Array = []
	for tr in DB.trains:
		for leg in tr["legs"]:
			if str(leg["line"]) == line_id:
				out.append(tr)
				break
	return out


func _rebuild() -> void:
	for c in trains_box.get_children():
		c.queue_free()
	var filter := search.text.strip_edges().to_lower()
	var shown := 0
	var total := 0
	for tr in _line_trains():
		total += 1
		var hay := (str(tr["code"]) + " " + str(tr["from"]) + " " + str(tr["to"])).to_lower()
		if filter != "" and not hay.contains(filter):
			continue
		trains_box.add_child(_make_row(tr))
		shown += 1
	count_label.text = "共 %d 趟 · 当前显示 %d 趟" % [total, shown]


func _make_row(tr: Dictionary) -> Button:
	var st: Dictionary = Simulation.states.get(tr["code"], {})
	var status_txt := ""
	match st.get("status", "off"):
		"run":
			status_txt = "在途 %d km/h" % int(st.get("speed_kmh", 0.0))
		"stop":
			status_txt = "停站"
		"wait":
			status_txt = "待发"
		"done":
			status_txt = "已终到"
		_:
			status_txt = "未上线"
	var line1 := "%s   %s 发   %s → %s" % [tr["code"],
			GameTime.fmt_hhmm_abs(tr["start_s"]), tr["from"], tr["to"]]
	var tt: Dictionary = DB.train_types.get(tr["type"], {})
	var tname: String = "货运示意" if bool(tr.get("freight", false)) else str(tt.get("name", "?"))
	var line2 := "%s · %s" % [tname, status_txt]
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = line1 + "\n" + line2
	b.add_theme_stylebox_override("normal", UIKit.flat(UIKit.CARD, 8, UIKit.BORDER, 1, 8))
	b.add_theme_stylebox_override("hover", UIKit.flat(Color("202a3c"), 8, UIKit.ACCENT, 1, 8))
	b.add_theme_stylebox_override("pressed", UIKit.flat(Color("202a3c"), 8, UIKit.ACCENT, 1, 8))
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", UIKit.TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.modulate = Color(1, 1, 1) if status_txt != "未上线" else Color(0.75, 0.75, 0.75)
	b.pressed.connect(func(): code_picked.emit(tr["code"]))
	return b


func _build_stations() -> void:
	for c in stations_box.get_children():
		c.queue_free()
	var line: Dictionary = DB.line(line_id)
	for sid in line["order"]:
		var st: Dictionary = line["stations"][sid]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var c1 := UIKit.label(("● " if st["major"] else "○ ") + str(st["name"]),
				13, UIKit.TEXT if st["major"] else UIKit.DIM)
		c1.custom_minimum_size = Vector2(130, 0)
		row.add_child(c1)
		row.add_child(UIKit.label("K%d" % int(st["km"]), 12, UIKit.ACCENT2))
		stations_box.add_child(row)

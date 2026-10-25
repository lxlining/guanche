# 线路详情面板：点击线路体打开。显示线路概况、全部车次（可搜索）、车站序列。
# 车次行点击 -> signal code_picked -> 联动地图选中与详情卡。
extends Control

signal code_picked(code: String)

const UIKit := preload("res://src/ui/ui_kit.gd")

var line_id := ""
var search: LineEdit
var trains_box: VBoxContainer
var stations_box: VBoxContainer
var tabs: TabContainer
var title_label: Label
var sub_label: Label
var count_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(cc)

	var panel := UIKit.panel_container(UIKit.flat(UIKit.CARD, 14, UIKit.BORDER, 1, 16))
	cc.add_child(panel)
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(860, 600)
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	vb.add_child(head)
	title_label = UIKit.label("线路", 20, Color.WHITE)
	head.add_child(title_label)
	sub_label = UIKit.label("", 12, UIKit.DIM)
	sub_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(sub_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	head.add_child(UIKit.button("关闭 [Esc]", func(): visible = false))

	count_label = UIKit.label("", 12, UIKit.ACCENT2)
	vb.add_child(count_label)

	search = LineEdit.new()
	search.placeholder_text = "搜索车次（如 G1 / D901 / C）或始发终到站名"
	search.clear_button_enabled = true
	search.text_changed.connect(func(_t: String): _rebuild())
	vb.add_child(search)

	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 14)
	vb.add_child(tabs)

	var tab1 := ScrollContainer.new()
	tab1.name = "车次"
	tabs.add_child(tab1)
	trains_box = VBoxContainer.new()
	trains_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trains_box.add_theme_constant_override("separation", 3)
	tab1.add_child(trains_box)

	var tab2 := ScrollContainer.new()
	tab2.name = "车站"
	tabs.add_child(tab2)
	stations_box = VBoxContainer.new()
	stations_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stations_box.add_theme_constant_override("separation", 2)
	tab2.add_child(stations_box)


func open(id: String) -> void:
	line_id = id
	visible = true
	_refresh()


func _refresh() -> void:
	var line: Dictionary = DB.line(line_id)
	title_label.text = str(line["name"])
	var cls_name: String = {"hsr350": "高铁 350", "hsr250": "高铁 200-250",
			"intercity": "城际", "conventional": "普速"}.get(
			DB.line_class(line_id), "铁路")
	sub_label.text = "%s · %s — %s" % [cls_name, line["from"], line["to"]]
	var trains := _line_trains()
	count_label.text = "%d 座车站 · %.0f km · 日均 %d 趟车" % [
			line["order"].size(), line["total_len_m"] / 1000.0, trains.size()]
	_rebuild()
	_build_stations()


func _line_trains() -> Array:
	var out: Array = []
	for tr in DB.trains:
		var hit := false
		for leg in tr["legs"]:
			if str(leg["line"]) == line_id:
				hit = true
				break
		if hit:
			out.append(tr)
	return out


func _rebuild() -> void:
	for c in trains_box.get_children():
		c.queue_free()
	var filter := search.text.strip_edges().to_lower()
	var shown := 0
	for tr in _line_trains():
		var hay := (str(tr["code"]) + " " + str(tr["from"]) + " " + str(tr["to"])).to_lower()
		if filter != "" and not hay.contains(filter):
			continue
		trains_box.add_child(_make_row(tr))
		shown += 1
	count_label.text = count_label.text.split(" · ")[0] + " · " + \
			count_label.text.split(" · ")[1] + " · 日均 %d 趟车（显示 %d）" % [
			_line_trains().size(), shown]


func _make_row(tr: Dictionary) -> Button:
	var st: Dictionary = Simulation.states.get(tr["code"], {})
	var status_txt := ""
	var status_col := UIKit.DIM
	match st.get("status", "off"):
		"run":
			status_txt = "在途 %d km/h" % int(st.get("speed_kmh", 0.0))
			status_col = UIKit.GOOD
		"stop":
			status_txt = "停站"
			status_col = UIKit.ACCENT2
		"wait":
			status_txt = "待发"
			status_col = UIKit.WARN
		"done":
			status_txt = "已终到"
		_:
			status_txt = "未上线"
	var line1 := "%s   %s 发   %s → %s" % [tr["code"],
			GameTime.fmt_hhmm_abs(tr["start_s"]), tr["from"], tr["to"]]
	var tt: Dictionary = DB.train_types.get(tr["type"], {})
	var line2 := "%s · %s" % [tt.get("name", "?"), status_txt]
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = line1 + "\n" + line2
	b.add_theme_stylebox_override("normal", UIKit.flat(UIKit.CARD, 8, UIKit.BORDER, 1, 8))
	b.add_theme_stylebox_override("hover", UIKit.flat(Color("202a3c"), 8, UIKit.ACCENT, 1, 8))
	b.add_theme_stylebox_override("pressed", UIKit.flat(Color("202a3c"), 8, UIKit.ACCENT, 1, 8))
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", status_col if false else UIKit.TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
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

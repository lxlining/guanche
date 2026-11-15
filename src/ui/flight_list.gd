# 航班列表侧栏（航空视图 Tab）：按剩余飞行时间排序的在途航班，
# 支持按航班号/航司/机场筛选，点击选中并定位。
extends PanelContainer

signal flight_selected(idx: int)

const UIKit := preload("res://src/ui/ui_kit.gd")

var search: LineEdit
var rows_box: VBoxContainer
var count_label: Label
var sort_btn: OptionButton
var sort_mode := "remain"   # remain=即将到达 / dep=即将起飞
var _refresh_accum := 0.0


func _ready() -> void:
	set_anchor(SIDE_LEFT, 1.0)
	set_anchor(SIDE_RIGHT, 1.0)
	set_anchor(SIDE_TOP, 0.0)
	set_anchor(SIDE_BOTTOM, 1.0)
	offset_left = -336
	offset_right = -14
	offset_top = 64
	offset_bottom = -132
	add_theme_stylebox_override("panel", UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 12))
	visible = false

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	var title := UIKit.label("✈ 航班动态", 16, Color.WHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := UIKit.button("×", func(): toggle())
	close_btn.custom_minimum_size = Vector2(30, 26)
	head.add_child(close_btn)

	count_label = UIKit.label("", 12, UIKit.DIM)
	vb.add_child(count_label)

	search = LineEdit.new()
	search.placeholder_text = "筛选：航班号 / 航司 / 机场，如 CA / 虹桥"
	search.clear_button_enabled = true
	search.text_changed.connect(func(_t: String): _rebuild())
	vb.add_child(search)

	sort_btn = OptionButton.new()
	sort_btn.add_item("按剩余飞行时间")
	sort_btn.set_item_metadata(0, "remain")
	sort_btn.add_item("按即将起飞")
	sort_btn.set_item_metadata(1, "dep")
	sort_btn.item_selected.connect(func(idx: int):
		sort_mode = str(sort_btn.get_item_metadata(idx))
		_rebuild())
	sort_btn.add_theme_font_size_override("font_size", 12)
	vb.add_child(sort_btn)

	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(sc)
	rows_box = VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_box.add_theme_constant_override("separation", 4)
	sc.add_child(rows_box)


func _process(delta: float) -> void:
	if visible and not FlightSim.flights.is_empty():
		_refresh_accum += delta
		if _refresh_accum > 4.0:
			_refresh_accum = 0.0
			_rebuild()


func toggle() -> void:
	visible = not visible
	if visible:
		_rebuild()


func _rebuild() -> void:
	if FlightSim.flights.is_empty():
		return
	for c in rows_box.get_children():
		c.queue_free()
	var filter := ""
	if search != null:
		filter = search.text.strip_edges().to_lower()
	var t := GameTime.t
	var rows: Array = []
	for idx in FlightSim.active_flights(t):
		var fl: Dictionary = FlightSim.flights[idx]
		var st: Dictionary = FlightSim.state_for(idx, t)
		var ph: String = str(st["phase"])
		if ph == "pre" or ph == "done":
			continue
		var hay: String = (str(fl["id"]) + " " + str(fl["al_name"]) + " "
				+ str(FlightSim.airports[fl["from"]]["city"]) + " "
				+ str(FlightSim.airports[fl["to"]]["city"])).to_lower()
		if filter != "" and not hay.contains(filter):
			continue
		var sort_key: float
		if sort_mode == "dep":
			sort_key = -fposmod(float(fl["dep"]) - t, 86400.0)
		else:
			sort_key = float(st["remain"])
		rows.append([sort_key, idx, fl, st, ph])
	rows.sort_custom(func(a, b): return a[0] < b[0])
	count_label.text = "在途 %d 班 · %s" % [rows.size(),
			"剩余时间升序" if sort_mode == "remain" else "即将起飞优先"]
	for r in rows.slice(0, 60):
		rows_box.add_child(_make_row(r[1], r[2], r[3], r[4]))


func _make_row(idx: int, fl: Dictionary, st: Dictionary, ph: String) -> Button:
	var from_city: String = FlightSim.airports[fl["from"]]["city"]
	var to_city: String = FlightSim.airports[fl["to"]]["city"]
	var line1 := "%s   %s → %s" % [str(fl["id"]), from_city, to_city]
	var ph_txt: String = str({"climb": "爬升", "cruise": "巡航", "descend": "下降"}.get(ph, ""))
	var line2 := "%s · %s · 高度 %.1f km · 余 %d 分钟" % [
		str(fl["al_name"]), ph_txt, float(st["alt"]) / 1000.0,
		int(float(st["remain"]) / 60.0)]
	var al_col := Color(str(fl["al_color"])).lightened(0.25)

	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = line1 + "\n" + line2
	b.add_theme_stylebox_override("normal", UIKit.flat(UIKit.CARD, 8, UIKit.BORDER, 1, 8))
	b.add_theme_stylebox_override("hover", UIKit.flat(Color("202a3c"), 8, UIKit.ACCENT, 1, 8))
	b.add_theme_stylebox_override("pressed", UIKit.flat(Color("202a3c"), 8, UIKit.ACCENT, 1, 8))
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", al_col)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.pressed.connect(flight_selected.emit.bind(idx))
	return b

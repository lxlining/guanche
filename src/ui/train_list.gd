# 列车列表侧栏：按发车时刻排序，支持按车次/车型筛选，点击定位并选中。
extends PanelContainer

signal train_selected(code: String)

const UIKit := preload("res://src/ui/ui_kit.gd")

var search: LineEdit
var rows_box: VBoxContainer
var count_label: Label
var line_filter_btn: OptionButton
var line_filter := ""
var _refresh_accum := 0.0


func _ready() -> void:
	set_anchor(SIDE_LEFT, 1.0)
	set_anchor(SIDE_RIGHT, 1.0)
	set_anchor(SIDE_TOP, 0.0)
	set_anchor(SIDE_BOTTOM, 1.0)
	offset_left = -336
	offset_right = -14
	offset_top = 64
	offset_bottom = -92
	add_theme_stylebox_override("panel", UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 12))
	visible = false

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	var title := UIKit.label("列车时刻表", 16, Color.WHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := UIKit.button("×", func(): toggle())
	close_btn.custom_minimum_size = Vector2(30, 26)
	head.add_child(close_btn)

	count_label = UIKit.label("", 12, UIKit.DIM)
	vb.add_child(count_label)

	search = LineEdit.new()
	search.placeholder_text = "筛选：车次或车型，如 G1 / CR400"
	search.clear_button_enabled = true
	search.text_changed.connect(func(_t: String): _rebuild())
	vb.add_child(search)

	line_filter_btn = OptionButton.new()
	line_filter_btn.add_item("全部线路")
	line_filter_btn.set_item_metadata(0, "")
	for line_id in DB.line_order:
		line_filter_btn.add_item(DB.lines[line_id]["short"])
		line_filter_btn.set_item_metadata(line_filter_btn.item_count - 1, line_id)
	line_filter_btn.item_selected.connect(func(idx: int):
		line_filter = str(line_filter_btn.get_item_metadata(idx))
		_rebuild())
	line_filter_btn.add_theme_font_size_override("font_size", 12)
	vb.add_child(line_filter_btn)

	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(sc)
	rows_box = VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_box.add_theme_constant_override("separation", 4)
	sc.add_child(rows_box)


func _process(delta: float) -> void:
	if visible:
		_refresh_accum += delta
		if _refresh_accum > 4.0:
			_refresh_accum = 0.0
			_rebuild()


func toggle() -> void:
	visible = not visible
	if visible:
		_rebuild()


func _rebuild() -> void:
	for c in rows_box.get_children():
		c.queue_free()
	var filter := ""
	if search != null:
		filter = search.text.strip_edges().to_lower()
	var shown := 0
	var active_count := 0
	for train in DB.trains:
		if line_filter != "" and train.get("line", "") != line_filter:
			continue
		var tt: Dictionary = DB.train_types.get(train["type"], {})
		var hay := (str(train["code"]) + " " + str(tt.get("name", "")) + " " + str(tt.get("family", ""))).to_lower()
		if filter != "" and not hay.contains(filter):
			continue
		if _is_active(train["code"]):
			active_count += 1
		rows_box.add_child(_make_row(train, tt))
		shown += 1
	count_label.text = "共 %d 趟 · 当前在图 %d 趟" % [shown, active_count]


func _make_row(train: Dictionary, tt: Dictionary) -> Button:
	var st: Dictionary = Simulation.states.get(train["code"], {})
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

	var dep_t: float = train["stops"][0]["dep_s"]
	var line_short: String = str(DB.line(str(train.get("line", "")))["short"])
	var line1 := "%s   %s 发   %s → %s" % [
		train["code"], GameTime.fmt_hhmm_abs(dep_t), train["from"], train["to"]]
	var source := "货运示意" if train.get("freight", false) else ("生成补充" if train.get("generated", false) else "12306 时刻")
	var line2 := "%s · %s · %s · %s" % [tt.get("name", "?"), status_txt, line_short, source]

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
	b.pressed.connect(_on_row.bind(train["code"]))
	return b


func _on_row(code: String) -> void:
	train_selected.emit(code)


func _is_active(code: String) -> bool:
	var s: String = Simulation.states.get(code, {}).get("status", "off")
	return s == "run" or s == "stop" or s == "wait"

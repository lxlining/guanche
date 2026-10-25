# 车型图鉴：车型收集（未发现显示剪影）+ 已观测车次列表。
extends Control

const UIKit := preload("res://src/ui/ui_kit.gd")
const EmuIllu := preload("res://src/ui/emu_illustration.gd")

var tabs: TabContainer
var types_grid: GridContainer
var trains_box: VBoxContainer
var title_label: Label


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
	vb.custom_minimum_size = Vector2(980, 620)
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	vb.add_child(head)
	title_label = UIKit.label("车型图鉴", 20, Color.WHITE)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	head.add_child(UIKit.button("关闭 [Esc]", func(): visible = false))

	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 14)
	vb.add_child(tabs)

	var tab1 := ScrollContainer.new()
	tab1.name = "车型"
	tabs.add_child(tab1)
	types_grid = GridContainer.new()
	types_grid.columns = 3
	types_grid.add_theme_constant_override("h_separation", 10)
	types_grid.add_theme_constant_override("v_separation", 10)
	types_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab1.add_child(types_grid)

	var tab2 := ScrollContainer.new()
	tab2.name = "车次"
	tabs.add_child(tab2)
	trains_box = VBoxContainer.new()
	trains_box.add_theme_constant_override("separation", 4)
	trains_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab2.add_child(trains_box)

	Meta.type_discovered.connect(_on_type_discovered)


func _on_type_discovered(_tid: String) -> void:
	if visible:
		refresh()


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func refresh() -> void:
	title_label.text = "车型图鉴 · %d / %d" % [Meta.discovered.size(), DB.type_list.size()]
	for c in types_grid.get_children():
		c.queue_free()
	for tt in DB.type_list:
		types_grid.add_child(_type_card(tt))

	for c in trains_box.get_children():
		c.queue_free()
	var codes: Array = Meta.spotted.keys()
	codes.sort_custom(func(a, b):
		return Meta.spotted[a]["first_t"] < Meta.spotted[b]["first_t"])
	if codes.is_empty():
		trains_box.add_child(UIKit.label("还没有观测到任何车次——点击地图上的列车开始你的第一次观测。", 13, UIKit.DIM))
	for code in codes:
		var sp: Dictionary = Meta.spotted[code]
		var train: Dictionary = DB.train_by_code.get(code, {})
		var line: Dictionary = DB.line(str(train.get("line", DB.line_order[0])))
		var tt: Dictionary = DB.train_types.get(train.get("type", ""), {})
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var c1 := UIKit.label(code, 14, Color.WHITE)
		c1.custom_minimum_size = Vector2(70, 0)
		row.add_child(c1)
		var c2 := UIKit.label(str(tt.get("name", "?")), 13, UIKit.ACCENT2)
		c2.custom_minimum_size = Vector2(120, 0)
		row.add_child(c2)
		var station: String = "—"
		var st: Dictionary = line["stations"].get(train.get("stops", [{}])[0].get("sid", ""), {})
		if not st.is_empty():
			station = st["name"]
		row.add_child(UIKit.label("%s · 首见 %s @ %s · 观测 %d 次" % [
			line["short"], GameTime.fmt_hhmm_abs(float(sp["first_t"])), station, int(sp["count"])], 12, UIKit.DIM))
		trains_box.add_child(row)


func _type_card(tt: Dictionary) -> PanelContainer:
	var found: bool = Meta.discovered.has(tt["id"])
	var col := Color(str(tt.get("color", "#888888")))
	var card := UIKit.panel_container(UIKit.flat(
			UIKit.CARD if found else Color("10151f"),
			10, col if found else UIKit.BORDER, 1, 12))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	var dot := UIKit.label("●", 16, col if found else Color(0.25, 0.28, 0.34))
	head.add_child(dot)
	var name_l := UIKit.label(str(tt["name"]) if found else "？？？", 16,
			Color.WHITE if found else Color(0.4, 0.45, 0.54))
	head.add_child(name_l)

	var illu := EmuIllu.new()
	illu.setup(tt, 58.0)
	vb.add_child(illu)

	vb.add_child(UIKit.label("%s · %s · %d km/h" % [
			tt.get("family", ""), tt.get("formation", ""), int(tt.get("speed", 0))],
			12, UIKit.ACCENT2 if found else Color(0.35, 0.4, 0.48)))
	var desc := UIKit.label(str(tt.get("desc", "")) if found else "尚未发现。放置机位或跟随列车来解锁。", 12,
			UIKit.TEXT if found else Color(0.4, 0.45, 0.54))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(280, 0)
	vb.add_child(desc)

	if found:
		var d: Dictionary = Meta.discovered[tt["id"]]
		vb.add_child(UIKit.label("首见 %s · %s · %s" % [
				GameTime.fmt_hhmm_abs(float(d["t"])), str(d["code"]), str(d["station"])],
				11, UIKit.GOOD))
	return card

# 成就界面：解锁状态与进度。
extends Control

const UIKit := preload("res://src/ui/ui_kit.gd")

var grid: GridContainer
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
	vb.custom_minimum_size = Vector2(760, 560)
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var head := HBoxContainer.new()
	vb.add_child(head)
	title_label = UIKit.label("成就", 20, Color.WHITE)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	head.add_child(UIKit.button("关闭 [Esc]", func(): visible = false))

	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(sc)
	grid = GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(grid)

	Meta.achievement_unlocked.connect(_on_unlocked)


func _on_unlocked(_a: Dictionary) -> void:
	if visible:
		refresh()


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func refresh() -> void:
	var done := 0
	for def in DB.achievements:
		if def["id"] in Meta.unlocked:
			done += 1
	title_label.text = "成就 · %d / %d" % [done, DB.achievements.size()]
	for c in grid.get_children():
		c.queue_free()
	for def in DB.achievements:
		grid.add_child(_ach_card(def))


func _ach_card(def: Dictionary) -> PanelContainer:
	var got: bool = def["id"] in Meta.unlocked
	var col := UIKit.WARN if got else UIKit.BORDER
	var card := UIKit.panel_container(UIKit.flat(
			Color("1c2230") if got else Color("11161f"), 10, col, 1, 12))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	head.add_child(UIKit.label(str(def["name"]), 15, Color.WHITE if got else Color(0.55, 0.6, 0.7)))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	head.add_child(UIKit.label("已解锁" if got else "未解锁", 12, UIKit.WARN if got else UIKit.DIM))

	vb.add_child(UIKit.label(str(def.get("desc", "")), 12, UIKit.TEXT if got else UIKit.DIM))
	var prog: String = Meta.progress_text(def)
	if prog != "" and not got:
		vb.add_child(UIKit.label("进度 " + prog, 11, UIKit.ACCENT2))
	return card

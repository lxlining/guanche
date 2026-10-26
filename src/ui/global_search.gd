# 全局搜索（置顶）：车次 / 车站 / 线路 三合一即时搜索。
# 结果分三组展示；选择后发信号给主场景处理（选中/飞至/打开页面）。
extends PanelContainer

signal train_picked(code: String)
signal station_picked(sname: String)
signal line_picked(line_id: String)

const UIKit := preload("res://src/ui/ui_kit.gd")

var search: LineEdit
var results_box: VBoxContainer
var results_panel: PanelContainer


func _ready() -> void:
	add_theme_stylebox_override("panel", UIKit.flat(Color("141a24f2"), 10, UIKit.ACCENT, 1, 8))
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	add_child(vb)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	vb.add_child(hb)
	var icon := UIKit.label("🔍", 15, UIKit.ACCENT2)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(icon)
	search = LineEdit.new()
	search.placeholder_text = "搜索：车次 / 车站 / 线路…"
	search.clear_button_enabled = true
	search.custom_minimum_size = Vector2(380, 30)
	search.add_theme_font_size_override("font_size", 14)
	search.text_changed.connect(func(_t: String): _refresh())
	search.text_submitted.connect(func(_t: String): _pick_first())
	hb.add_child(search)
	results_panel = PanelContainer.new()
	results_panel.add_theme_stylebox_override("panel", UIKit.flat(Color("10151fe8"), 8, UIKit.BORDER, 1, 4))
	results_panel.visible = false
	vb.add_child(results_panel)
	results_box = VBoxContainer.new()
	results_box.add_theme_constant_override("separation", 1)
	results_panel.add_child(results_box)


func _refresh() -> void:
	for c in results_box.get_children():
		c.queue_free()
	var q := search.text.strip_edges().to_lower()
	if q == "":
		results_panel.visible = false
		return
	var found := 0
	# 车次
	var trains: Array = []
	for tr in DB.trains:
		if str(tr["code"]).to_lower().begins_with(q):
			trains.append(tr)
		if trains.size() >= 3:
			break
	for tr in trains:
		results_box.add_child(_row("🚄", str(tr["code"]),
				"%s → %s" % [tr["from"], tr["to"]], func(): train_picked.emit(tr["code"])))
		found += 1
	# 车站
	var stations: Array = []
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		for sid in line["order"]:
			var nm: String = line["stations"][sid]["name"]
			if nm.to_lower().begins_with(q) and not _station_listed(stations, nm):
				stations.append(nm)
				if stations.size() >= 4:
					break
		if stations.size() >= 4:
			break
	for nm in stations:
		results_box.add_child(_row("📍", nm, "车站", func(): station_picked.emit(nm)))
		found += 1
	# 线路
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		if str(line["short"]).to_lower().contains(q) or str(line["name"]).to_lower().contains(q):
			results_box.add_child(_row("🛤", str(line["short"]),
					"%d 站 · %d 趟/日" % [line["order"].size(), _line_trains(line_id)],
					func(): line_picked.emit(line_id)))
			found += 1
			if found >= 10:
				break
	results_panel.visible = found > 0


func _station_listed(arr: Array, nm: String) -> bool:
	return nm in arr


func _line_trains(line_id: String) -> int:
	var n := 0
	for tr in DB.trains:
		for leg in tr["legs"]:
			if str(leg["line"]) == line_id:
				n += 1
				break
	return n


func _row(icon_text: String, title: String, sub: String, action: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = "%s  %s   %s" % [icon_text, title, sub]
	b.flat = true
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", UIKit.TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.pressed.connect(func():
		action.call()
		search.text = ""
		_refresh()
		results_panel.visible = false)
	return b


func _pick_first() -> void:
	if results_box.get_child_count() > 0:
		var first := results_box.get_child(0) as Button
		first.pressed.emit()

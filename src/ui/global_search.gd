# 全局搜索（置顶）：车次 / 车站 / 线路 三合一即时搜索。
# 支持拼音首字母与全拼（如 jnx → 济南西）；空查询时展示最近搜索。
# 结果分三组展示；选择后发信号给主场景处理（选中/飞至/打开页面）。
extends PanelContainer

signal train_picked(code: String)
signal station_picked(sname: String)
signal line_picked(line_id: String)

const UIKit := preload("res://src/ui/ui_kit.gd")

const PINYIN_PATH := "res://data/pinyin_map.json"

static var _pinyin: Dictionary = {}

var search: LineEdit
var results_box: VBoxContainer
var results_panel: PanelContainer
var _focus_in := false


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
	search.placeholder_text = "搜索：车次 / 车站 / 线路 / 拼音…"
	search.clear_button_enabled = true
	search.custom_minimum_size = Vector2(380, 30)
	search.add_theme_font_size_override("font_size", 14)
	search.text_changed.connect(func(_t: String): _refresh())
	search.text_submitted.connect(func(_t: String): _on_submit())
	search.focus_entered.connect(func():
		_focus_in = true
		_refresh())
	search.focus_exited.connect(func():
		_focus_in = false
		get_tree().create_timer(0.2).timeout.connect(func():
			if not _focus_in:
				results_panel.visible = false))
	hb.add_child(search)
	results_panel = PanelContainer.new()
	results_panel.add_theme_stylebox_override("panel", UIKit.flat(Color("10151fe8"), 8, UIKit.BORDER, 1, 4))
	results_panel.visible = false
	vb.add_child(results_panel)
	results_box = VBoxContainer.new()
	results_box.add_theme_constant_override("separation", 1)
	results_panel.add_child(results_box)


static func _load_pinyin() -> Dictionary:
	if _pinyin.is_empty():
		var f := FileAccess.open(PINYIN_PATH, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			if typeof(parsed) == TYPE_DICTIONARY:
				_pinyin = parsed
	return _pinyin


# 站名 → (全拼串, 首字母串)；带 16 条缓存
static var _py_cache: Dictionary = {}


static func _station_pinyin(nm: String) -> Array:
	if _py_cache.has(nm):
		return _py_cache[nm]
	var table := _load_pinyin()
	var fulls := [""]
	var inits := [""]
	for c in nm:
		if table.has(c):
			var reads: Array = table[c]
			var nf := []
			var ni := []
			for base in fulls:
				for r in reads:
					nf.append(base + r)
					ni.append(base + r.substr(0, 1))
			fulls = nf.slice(0, 64)
			inits = ni.slice(0, 64)
		else:
			var nf2 := []
			var ni2 := []
			for base in fulls:
				nf2.append(base + c)
				ni2.append(base + c)
			fulls = nf2
			inits = ni2
	var res := [fulls, inits]
	_py_cache[nm] = res
	if _py_cache.size() > 4096:
		_py_cache.clear()
	return res


static func _py_match(nm: String, q: String) -> bool:
	var pv := _station_pinyin(nm)
	for full in pv[0]:
		if full.begins_with(q):
			return true
	for ini in pv[1]:
		if ini.begins_with(q):
			return true
	return false


func _refresh() -> void:
	for c in results_box.get_children():
		c.queue_free()
	var q := search.text.strip_edges().to_lower()
	if q == "":
		_show_history()
		return
	var found := 0
	var is_ascii := not _has_cjk(q)
	# 车站（拼音支持需要 ASCII 查询）
	var stations: Array = []
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		for sid in line["order"]:
			var nm: String = line["stations"][sid]["name"]
			if _station_listed(stations, nm):
				continue
			var hit := nm.to_lower().contains(q) if not is_ascii else \
					nm.to_lower().contains(q) or _py_match(nm, q)
			if hit:
				stations.append(nm)
				if stations.size() >= 4:
					break
		if stations.size() >= 4:
			break
	for nm in stations:
		results_box.add_child(_row("📍", nm, "车站", func(): station_picked.emit(nm)))
		found += 1
	# 车次（≥2 字符时包含匹配）
	var trains: Array = []
	for tr in DB.trains:
		var code := str(tr["code"]).to_lower()
		if code.begins_with(q) or (q.length() >= 2 and code.contains(q)):
			trains.append(tr)
		if trains.size() >= 3:
			break
	for tr in trains:
		results_box.add_child(_row("🚄", str(tr["code"]),
				"%s → %s" % [tr["from"], tr["to"]], func(): train_picked.emit(tr["code"])))
		found += 1
	# 线路
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		if str(line["short"]).to_lower().contains(q) or str(line["name"]).to_lower().contains(q):
			results_box.add_child(_row("🛤", str(line["short"]),
					"%d 站 · %d 趟/日" % [line["order"].size(), _line_trains(line_id)],
					func(): line_picked.emit(line_id)))
			found += 1
			if found >= 12:
				break
	results_panel.visible = found > 0


func _has_cjk(q: String) -> bool:
	for c in q:
		if c.unicode_at(0) > 0x4e00 - 1 and c.unicode_at(0) < 0xa000:
			return true
	return false


func _show_history() -> void:
	if not _focus_in or Meta.search_history.is_empty():
		results_panel.visible = false
		return
	results_box.add_child(_label("最近搜索"))
	for q in Meta.search_history:
		results_box.add_child(_row("🕘", q, "回车重搜", func():
			search.text = q
			_refresh()))
	results_panel.visible = true


func _label(txt: String) -> Label:
	var l := UIKit.label(txt, 11, UIKit.DIM)
	l.custom_minimum_size = Vector2(0, 20)
	return l


func _on_submit() -> void:
	Meta.push_search(search.text)
	_pick_first()


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
		var q := search.text.strip_edges()
		if q != "":
			Meta.push_search(q)
		action.call()
		search.text = ""
		_refresh()
		results_panel.visible = false)
	return b


func _pick_first() -> void:
	if results_box.get_child_count() > 0:
		var first := results_box.get_child(0) as Button
		first.pressed.emit()

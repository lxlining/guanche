# 主 UI 外壳：时钟、时间控制条、顶部按钮、跟随/机位提示、成就弹窗、帮助与各子界面。
extends CanvasLayer

signal train_search_picked(code: String)
signal cam_jump_requested(world_pos: Vector2)
signal flight_picked(idx: int)

const UIKit := preload("res://src/ui/ui_kit.gd")
const FontLib := preload("res://src/ui/font_lib.gd")
const TrainList := preload("res://src/ui/train_list.gd")
const DetailCard := preload("res://src/ui/detail_card.gd")
const DexScreen := preload("res://src/ui/dex_screen.gd")
const AchievementsScreen := preload("res://src/ui/achievements_screen.gd")
const DiagramView := preload("res://src/ui/diagram_view.gd")
const StationCard := preload("res://src/ui/station_card.gd")
const YardView := preload("res://src/ui/yard_view.gd")
const LineScreen := preload("res://src/ui/line_screen.gd")
const GlobalSearch := preload("res://src/ui/global_search.gd")
const MiniMap := preload("res://src/ui/mini_map.gd")
const FlightCard := preload("res://src/ui/flight_card.gd")
const AirportCard := preload("res://src/ui/airport_card.gd")

var ui_root: Control
var clock_label: Label
var clock_sub: Label
var follow_pill: PanelContainer
var checkin_pill: PanelContainer
var checkin_label: Label
var checkin_btn: Button
var checkin_book: PanelContainer
var checkin_book_list: VBoxContainer
var checkin_book_progress: Label
var checkin_target := ""   # 当前可打卡站名（空 = 不可打卡）
var yard_view: Control
var follow_label: Label
var spot_pill: PanelContainer
var toast_box: VBoxContainer
var pause_btn: Button
var speed_buttons: Array = []  # [Button, speed]
var jump_h: SpinBox
var jump_m: SpinBox

var detail: Control
var train_list: Control
var dex: Control
var ach_screen: Control
var diagram: Control
var station_card: Control
var mini_map: Control
var line_screen: Control
var global_search: Control
var flight_card: Control
var airport_card: Control
var focus_pill: PanelContainer
var focus_label: Label
var help_panel: Control


func _ready() -> void:
	layer = 10
	_build_root()
	_build_clock()
	_build_global_search()
	_build_legend()
	_build_top_buttons()
	_build_checkin_ui()
	_build_yard_view()
	_build_toast()
	_build_time_bar()
	_build_pills()
	_build_toasts()

	detail = DetailCard.new()
	ui_root.add_child(detail)
	train_list = TrainList.new()
	ui_root.add_child(train_list)
	dex = DexScreen.new()
	ui_root.add_child(dex)
	ach_screen = AchievementsScreen.new()
	ui_root.add_child(ach_screen)
	diagram = DiagramView.new()
	ui_root.add_child(diagram)
	station_card = StationCard.new()
	station_card.train_picked.connect(func(code: String):
		station_card.hide()
		train_search_picked.emit(code))
	ui_root.add_child(station_card)
	mini_map = MiniMap.new()
	mini_map.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	mini_map.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	mini_map.grow_vertical = Control.GROW_DIRECTION_BEGIN
	mini_map.jump_requested.connect(func(wpos: Vector2):
		cam_jump_requested.emit(wpos))
	ui_root.add_child(mini_map)
	_build_zoom_widget()
	line_screen = LineScreen.new()
	ui_root.add_child(line_screen)
	flight_card = FlightCard.new()
	ui_root.add_child(flight_card)
	airport_card = AirportCard.new()
	airport_card.flight_picked.connect(func(idx: int):
		airport_card.hide()
		flight_picked.emit(idx))
	ui_root.add_child(airport_card)
	_build_help()

	focus_pill = UIKit.panel_container(UIKit.flat(Color("1a2230e6"), 10, UIKit.WARN, 1, 10))
	focus_pill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 92)
	focus_pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	focus_label = UIKit.label("", 13, UIKit.WARN)
	focus_pill.add_child(focus_label)
	focus_pill.visible = false
	ui_root.add_child(focus_pill)
	Meta.focus_line_changed.connect(_on_focus_changed)
	Meta.achievement_unlocked.connect(_on_achievement)
	Meta.type_discovered.connect(_on_type_discovered)
	Meta.spot_mode_changed.connect(_on_spot_mode)
	Meta.aviation_changed.connect(_on_aviation_changed)
	if Meta.aviation_on:
		_on_aviation_changed()
	GameTime.speed_changed.connect(_sync_time_controls)
	GameTime.jumped.connect(_sync_time_controls)
	_sync_time_controls()
	_on_spot_mode(Meta.spot_mode)


func _build_root() -> void:
	ui_root = Control.new()
	ui_root.name = "UIRoot"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font = FontLib.get_font()
	theme.default_font_size = 14
	ui_root.theme = theme
	add_child(ui_root)


func _build_clock() -> void:
	var p := UIKit.panel_container(UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 12))
	p.position = Vector2(14, 14)
	ui_root.add_child(p)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 0)
	clock_label = UIKit.label("07:00", 30, Color.WHITE)
	clock_sub = UIKit.label("60× · %d 条线路 · %d 站" % [DB.line_order.size(), DB.total_station_count()], 12, UIKit.DIM)
	vb.add_child(clock_label)
	vb.add_child(clock_sub)
	p.add_child(vb)


const LEGEND_CLASSES := [
	["hsr350", "高铁 350km/h", "#6272e0"],
	["hsr250", "高铁 200-250", "#fb923c"],
	["intercity", "城际铁路", "#34d399"],
	["conventional", "普速铁路", "#94a3b8"],
	["freight", "货运专线（示意）", "#b45309"],
]

var legend_buttons: Array = []
var legend_panel: PanelContainer
var zoom_panel: PanelContainer
var zoom_label: Label


# 缩放控件：＋/－/全国复位 + 视野宽度指示（小地图上方，双视图通用）
func _build_zoom_widget() -> void:
	zoom_panel = UIKit.panel_container(UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 6))
	zoom_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	zoom_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	zoom_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	zoom_panel.offset_bottom = -172
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)
	zoom_panel.add_child(hb)
	hb.add_child(UIKit.button("＋", func(): _cam().zoom_step(1.4)))
	hb.add_child(UIKit.button("－", func(): _cam().zoom_step(1.0 / 1.4)))
	hb.add_child(UIKit.button("⤢ 全国", func(): _cam().zoom_reset_nation()))
	zoom_label = UIKit.label("", 11, UIKit.DIM)
	zoom_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(zoom_label)
	ui_root.add_child(zoom_panel)


func _cam() -> Camera2D:
	return get_viewport().get_camera_2d()


func _build_legend() -> void:
	var p := UIKit.panel_container(UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 10))
	p.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	ui_root.add_child(p)
	legend_panel = p
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	p.add_child(vb)
	vb.add_child(UIKit.label("线路等级", 12, UIKit.DIM))
	for entry in LEGEND_CLASSES:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		var chip := UIKit.label("▬", 12, Color(entry[2]))
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(chip)
		var b := Button.new()
		b.text = entry[1]
		b.toggle_mode = true
		b.button_pressed = Meta.is_class_visible(entry[0])
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 11)
		b.add_theme_color_override("font_color", UIKit.TEXT)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.flat = true
		b.toggled.connect(func(on: bool): Meta.set_class_visible(entry[0], on))
		hb.add_child(b)
		legend_buttons.append([b, entry[0]])
		vb.add_child(hb)
	Meta.class_visibility_changed.connect(_sync_legend)


func _sync_legend() -> void:
	for pair in legend_buttons:
		(pair[0] as Button).set_pressed_no_signal(Meta.is_class_visible(pair[1]))


func _build_top_buttons() -> void:
	var hb := HBoxContainer.new()
	hb.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	hb.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hb.add_theme_constant_override("separation", 8)
	ui_root.add_child(hb)
	hb.add_child(UIKit.button("运行图 [G]", func(): toggle_diagram()))
	hb.add_child(UIKit.button("打卡簿 [J]", func(): toggle_checkin_book()))
	hb.add_child(UIKit.button("车型图鉴 [D]", func(): toggle_dex()))
	hb.add_child(UIKit.button("成就 [A]", func(): toggle_ach()))
	var air_btn := UIKit.button("✈ 航空 [F8]", func(): Meta.set_aviation(not Meta.aviation_on))
	air_btn.name = "AirButton"
	hb.add_child(air_btn)
	var spot_btn := UIKit.button("机位模式 [P]", func(): Meta.toggle_spot_mode())
	spot_btn.name = "SpotButton"
	hb.add_child(spot_btn)
	hb.add_child(UIKit.button("帮助 [F1]", func(): toggle_help()))


func _build_checkin_ui() -> void:
	# 打卡横幅（跟随横幅下方）
	checkin_pill = UIKit.panel_container(UIKit.flat(Color("1a2230e6"), 10, UIKit.ACCENT, 1, 10))
	checkin_pill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 44)
	checkin_pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var hbx := HBoxContainer.new()
	hbx.add_theme_constant_override("separation", 10)
	checkin_pill.add_child(hbx)
	var icon := UIKit.label("📍", 15, UIKit.ACCENT2)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbx.add_child(icon)
	checkin_label = UIKit.label("", 14, UIKit.TEXT)
	checkin_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbx.add_child(checkin_label)
	checkin_btn = UIKit.button("打卡", func(): _do_checkin())
	checkin_btn.custom_minimum_size = Vector2(72, 26)
	hbx.add_child(checkin_btn)
	checkin_pill.visible = false
	ui_root.add_child(checkin_pill)

	# 打卡簿面板（右侧，类似成就页）
	checkin_book = UIKit.panel_container(UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 12))
	checkin_book.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	checkin_book.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	checkin_book.grow_vertical = Control.GROW_DIRECTION_BOTH
	checkin_book.custom_minimum_size = Vector2(360, 0)
	checkin_book.visible = false
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	checkin_book.add_child(vb)
	var head := HBoxContainer.new()
	vb.add_child(head)
	head.add_child(UIKit.label("📍 打卡簿", 18, Color.WHITE))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	head.add_child(UIKit.button("×", func(): toggle_checkin_book()))
	checkin_book_progress = UIKit.label("", 13, UIKit.ACCENT2)
	vb.add_child(checkin_book_progress)
	vb.add_child(UIKit.hspace(4))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(336, 420)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	checkin_book_list = VBoxContainer.new()
	checkin_book_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checkin_book_list.add_theme_constant_override("separation", 2)
	scroll.add_child(checkin_book_list)
	Meta.achievement_unlocked.connect(func(ach: Dictionary):
		if str(ach.get("check", "")) == "checkins_min":
			show_toast("🏅 成就解锁：%s" % str(ach.get("name", ""))))
	Meta.checkin_made.connect(func(_sname: String, _total: int):
		_refresh_checkin_book()
		_sync_checkin_pill())
	ui_root.add_child(checkin_book)


var toast_label: Label
var toast_timer := 0.0


var toast_panel: PanelContainer


func _build_yard_view() -> void:
	yard_view = YardView.new()
	yard_view.name = "YardView"
	ui_root.add_child(yard_view)


func open_yard_view(sname: String, pos: Vector2) -> void:
	yard_view.open(sname, pos)


func _build_toast() -> void:
	toast_panel = UIKit.panel_container(UIKit.flat(Color("1a2230ee"), 10, UIKit.ACCENT2, 1, 10))
	toast_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP,
			Control.PRESET_MODE_MINSIZE, 76)
	toast_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast_label = UIKit.label("", 14, Color.WHITE)
	toast_panel.add_child(toast_label)
	toast_panel.visible = false
	ui_root.add_child(toast_panel)


func show_toast(text: String) -> void:
	toast_label.text = text
	toast_panel.visible = true
	toast_timer = 3.0


func _do_checkin() -> void:
	if checkin_target == "":
		return
	var first := Meta.checkin(checkin_target)
	if first:
		checkin_btn.text = "✓ 已打卡"
		checkin_btn.disabled = true


func set_checkin_target(sname: String, checked: bool) -> void:
	checkin_target = sname
	if sname == "":
		checkin_pill.visible = false
		return
	checkin_pill.visible = true
	checkin_label.text = "靠近 %s" % sname
	if checked:
		checkin_btn.text = "✓ 已打卡"
		checkin_btn.disabled = true
	else:
		checkin_btn.text = "📍 打卡"
		checkin_btn.disabled = false


func toggle_checkin_book() -> void:
	checkin_book.visible = not checkin_book.visible
	if checkin_book.visible:
		_refresh_checkin_book()


func _station_lines(sname: String) -> String:
	var parts: Array = []
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		for sid in line["order"]:
			if line["stations"][sid]["name"] == sname:
				parts.append(str(line["short"]))
				break
	return " / ".join(parts)


func _refresh_checkin_book() -> void:
	checkin_book_progress.text = "已打卡 %d / %d 站 · 足迹 %.1f%%" % [
		Meta.checkin_total(), DB.total_station_count(),
		100.0 * Meta.checkin_total() / maxf(DB.total_station_count(), 1)]
	for c in checkin_book_list.get_children():
		c.queue_free()
	# 成就进度
	for def in DB.achievements:
		if def.get("check") != "checkins_min":
			continue
		var unlocked: bool = def["id"] in Meta.unlocked
		var prog: String = Meta.progress_text(def)
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s %s · %s%s" % ["🏅" if unlocked else "🔒", def["name"],
				prog, "　已达成" if unlocked else ""]
		b.flat = true
		b.disabled = true
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color",
				UIKit.ACCENT2 if unlocked else UIKit.DIM)
		checkin_book_list.add_child(b)
	checkin_book_list.add_child(UIKit.hspace(4))
	checkin_book_list.add_child(UIKit.label("最近打卡", 11, UIKit.DIM))
	# 打卡行（线路徽章 + 点击飞站）
	var rows: Array = []
	var line_count := {}
	for sname in Meta.checkins:
		var rec: Dictionary = Meta.checkins[sname]
		rows.append([float(rec.get("t", 0.0)), sname, int(rec.get("n", 1))])
	rows.sort_custom(func(a, b): return a[0] > b[0])
	for r in rows:
		var t: float = r[0]
		var sname: String = r[1]
		var lines_txt := _station_lines(sname)
		for ln in lines_txt.split(" / "):
			line_count[ln] = true
		var hh := int(fmod(t / 3600.0, 24.0))
		var mm := int(fmod(t / 60.0, 60.0))
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "📍 %s    %02d:%02d%s%s" % [sname, hh, mm,
				"（%d 次）" % r[2] if r[2] > 1 else "",
				"  ·  %s" % lines_txt if lines_txt != "" else ""]
		b.flat = true
		b.add_theme_font_size_override("font_size", 12)
		b.add_theme_color_override("font_color", UIKit.TEXT)
		b.tooltip_text = "点击飞至该站"
		b.pressed.connect(func():
			if DB._name_pos.has(sname):
				checkin_book.visible = false
				cam_jump_requested.emit(DB._name_pos[sname]))
		checkin_book_list.add_child(b)
	if rows.is_empty():
		checkin_book_list.add_child(UIKit.label(
				"还没有打卡记录。
靠近任意车站（3km 内）即可打卡。", 12, UIKit.DIM))
	else:
		# 线路打卡热力：按该线已打卡比例排序
		var heat: Array = []
		for line_id in DB.line_order:
			var line: Dictionary = DB.lines[line_id]
			var total: int = line["order"].size()
			var got: int = 0
			for sid in line["order"]:
				if Meta.checkins.has(str(line["stations"][sid]["name"])):
					got += 1
			if got > 0:
				heat.append([got / float(total), str(line["short"]), got, total])
		heat.sort_custom(func(a, b): return a[0] > b[0])
		var sp := Control.new()
		sp.custom_minimum_size = Vector2(0, 8)
		checkin_book_list.add_child(sp)
		checkin_book_list.add_child(UIKit.label(
				"共 %d 站 · 覆盖 %d 条线路 · 线路打卡热力" % [rows.size(), heat.size()],
				11, UIKit.DIM))
		for h in heat.slice(0, 12):
			var bar := ProgressBar.new()
			bar.min_value = 0.0
			bar.max_value = 1.0
			bar.value = h[0]
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(64, 10)
			var hb2 := HBoxContainer.new()
			hb2.add_theme_constant_override("separation", 8)
			var lbl := UIKit.label("🛤 %s  %d/%d" % [h[1], h[2], h[3]], 12, UIKit.TEXT)
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hb2.add_child(lbl)
			hb2.add_child(bar)
			checkin_book_list.add_child(hb2)
		if heat.size() > 12:
			checkin_book_list.add_child(UIKit.label(
					"…另有 %d 条线路已涉及" % (heat.size() - 12), 11, UIKit.DIM))


func _sync_checkin_pill() -> void:
	if checkin_target != "" and Meta.checkins.has(checkin_target):
		checkin_btn.text = "✓ 已打卡"
		checkin_btn.disabled = true


func _build_time_bar() -> void:
	var p := UIKit.panel_container(UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 10))
	p.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 14)
	p.grow_horizontal = Control.GROW_DIRECTION_BOTH
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ui_root.add_child(p)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	p.add_child(hb)

	pause_btn = UIKit.button("Ⅱ 暂停")
	pause_btn.toggle_mode = true
	pause_btn.toggled.connect(func(on: bool): GameTime.paused = on)
	hb.add_child(pause_btn)

	for s in [0.5, 1.0, 30.0, 60.0, 180.0, 600.0, 1800.0]:
		var b := UIKit.button("%s×" % _fmt_speed(s))
		b.toggle_mode = true
		b.toggled.connect(_on_speed_toggled.bind(s))
		hb.add_child(b)
		speed_buttons.append([b, s])

	hb.add_child(UIKit.hspace(8))
	hb.add_child(UIKit.label("跳转", 12, UIKit.DIM))
	for tm in [[6, 30], [9, 0], [12, 0], [18, 0], [22, 0]]:
		var h: int = tm[0]
		var m: int = tm[1]
		hb.add_child(UIKit.button("%02d:%02d" % [h, m], func(): GameTime.jump_to(h, m)))
	hb.add_child(UIKit.label("时刻", 12, UIKit.DIM))
	jump_h = SpinBox.new()
	jump_h.min_value = 0
	jump_h.max_value = 23
	jump_h.value = 7
	jump_h.custom_minimum_size = Vector2(58, 0)
	jump_m = SpinBox.new()
	jump_m.min_value = 0
	jump_m.max_value = 59
	jump_m.value = 30
	jump_m.custom_minimum_size = Vector2(58, 0)
	hb.add_child(jump_h)
	hb.add_child(jump_m)
	hb.add_child(UIKit.button("前往", func(): GameTime.jump_to(int(jump_h.value), int(jump_m.value))))


func _build_pills() -> void:
	follow_pill = UIKit.panel_container(UIKit.flat(Color("1a2230e6"), 10, UIKit.ACCENT, 1, 10))
	follow_pill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)
	follow_pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	follow_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	follow_label = UIKit.label("", 13, UIKit.ACCENT2)
	follow_pill.add_child(follow_label)
	follow_pill.visible = false
	ui_root.add_child(follow_pill)

	spot_pill = UIKit.panel_container(UIKit.flat(Color("1a2230e6"), 10, UIKit.GOOD, 1, 10))
	spot_pill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 52)
	spot_pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	spot_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sl := UIKit.label("机位模式：左键放置/移动机位 · 右键删除附近机位 · [P] 退出", 13, UIKit.GOOD)
	spot_pill.add_child(sl)
	spot_pill.visible = false
	ui_root.add_child(spot_pill)


func _build_toasts() -> void:
	toast_box = VBoxContainer.new()
	toast_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 92)
	toast_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast_box.grow_vertical = Control.GROW_DIRECTION_END
	toast_box.add_theme_constant_override("separation", 6)
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(toast_box)


func _build_help() -> void:
	help_panel = Control.new()
	help_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	help_panel.visible = false
	ui_root.add_child(help_panel)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	help_panel.add_child(dim)

	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	help_panel.add_child(cc)

	var p := UIKit.panel_container(UIKit.flat(UIKit.CARD, 14, UIKit.BORDER, 1, 18))
	cc.add_child(p)
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(620, 0)
	vb.add_theme_constant_override("separation", 8)
	p.add_child(vb)

	vb.add_child(UIKit.label("观车·京沪 — 玩法与操作", 20, Color.WHITE))
	var rich := RichTextLabel.new()
	rich.bbcode_enabled = true
	rich.fit_content = true
	rich.custom_minimum_size = Vector2(620, 0)
	rich.add_theme_color_override("default_color", UIKit.TEXT)
	rich.text = """[b]你是一名铁路车迷，京沪高铁的列车正按时刻表昼夜运行。[/b]
放置观测机位、跟踪列车、翻看时刻，收集你遇见的每一种车型与车次，解锁成就。

[b]操作[/b]
· 左键拖拽：移动地图　· 滚轮：缩放　· 左键点击列车：查看详情
· [F] 跟随选中列车　· [Esc] 关闭窗口 / 退出跟随　· [Space] 暂停
· [Tab] 列车列表　· [G] 运行图（时刻-距离图）　· [P] 机位模式　· [D] 图鉴　· [A] 成就

[b]航空模式 [F8][/b]
· 全国 100 座机场、3911 条航线、每日 7800+ 班航班同时运行（OpenFlights 开放数据）。
· 点击飞机查看航班详情（航司/高度/速度/进度），点「跟随」伴飞全程；点击机场看出发大屏。

[b]运行图[/b]
· 所有列车按「到发时刻 × 里程」画成经典斜线：右上行的下行车、左上行的上行车。
· 红色竖线是当前时刻，左右拖动即可平移时间；每个彩点是一趟在线列车的实时位置。
· 点击任意斜线即可选中该列车（与地图、详情卡联动）。

[b]观测与图鉴[/b]
· 点击列车或跟随列车都会收录该车的车型与车次。
· 机位模式下可在地图任意处放置至多 5 个机位，经过半径内的列车会被自动记录——蹲守大站或咽喉区间都很有趣。
· 底部时间条可暂停、变速、跳转时刻：去看清晨的首班车、晚间的末班车，或周末才有的临客。

[b]数据说明[/b]
· 车次与到发时刻来自 12306 公开查询接口的真实数据（2026-10-29 查询日），
· 始发/终到可能在线路图之外（跨线车驶离本线后消失属正常现象）。
· 12306 不公开车底（车型）信息，图鉴中的车型为按交路特征推测的标注，仅供参考。
· 本作与铁路运营方无关联。"""
	vb.add_child(rich)
	vb.add_child(UIKit.vspace(4))
	vb.add_child(UIKit.button("开始探索", func(): help_panel.visible = false, "primary"))


# ---------- 行为 ----------

func _process(delta: float) -> void:
	if toast_timer > 0.0:
		toast_timer -= delta
		if toast_timer <= 0.0:
			toast_panel.visible = false
	if clock_label != null:
		clock_label.text = ("Ⅱ " if GameTime.paused else "") + GameTime.time_string_full()
		clock_sub.text = "%s× · %d 条线路 · %d 站 · 在图 %d 趟" % [
			_fmt_speed(GameTime.speed), DB.line_order.size(), DB.total_station_count(), _active_count()]
	if zoom_label != null:
		var cam := get_viewport().get_camera_2d()
		if cam != null:
			var vp_w_m: float = get_viewport().get_visible_rect().size.x / cam.zoom.x
			zoom_label.text = "视野 ≈ %s" % _fmt_span(vp_w_m)


func _fmt_span(m: float) -> String:
	if m >= 100000.0:
		return "%.0f km" % (m / 1000.0)
	return "%.0f km" % (m / 1000.0)


func _active_count() -> int:
	var n := 0
	for code in Simulation.states:
		var s: String = Simulation.states[code].get("status", "off")
		if s == "run" or s == "stop" or s == "wait":
			n += 1
	return n


func _fmt_speed(s: float) -> String:
	if s == int(s):
		return str(int(s))
	return str(s)


func _on_speed_toggled(on: bool, s: float) -> void:
	if on:
		GameTime.set_speed(s)


func _sync_time_controls() -> void:
	pause_btn.set_pressed_no_signal(GameTime.paused)
	for pair in speed_buttons:
		var b: Button = pair[0]
		b.set_pressed_no_signal(is_equal_approx(pair[1], GameTime.speed))


func _on_achievement(ach: Dictionary) -> void:
	toast("成就解锁 · " + str(ach.get("name", "")), str(ach.get("desc", "")), UIKit.WARN)


func _on_type_discovered(type_id: String) -> void:
	var tt: Dictionary = DB.train_types.get(type_id, {})
	toast("图鉴更新", "首次发现 %s（%s）" % [tt.get("name", type_id), tt.get("family", "")], UIKit.GOOD)


func sync_focus_pill() -> void:
	_on_focus_changed()


func _on_focus_changed() -> void:
	if Meta.focus_train != "":
		focus_pill.visible = true
		var tr: Dictionary = DB.train_by_code.get(Meta.focus_train, {})
		focus_label.text = "车次专注：仅显示 %s 及其走线 · [Esc] 退出" % tr.get("code", "")
	elif Meta.focus_line != "":
		focus_pill.visible = true
		focus_label.text = "线路专注：%s · 点击其他线路切换 · [Esc] 退出" % DB.line(Meta.focus_line)["short"]
	else:
		focus_pill.visible = false


func open_station_by_name(sname: String) -> void:
	for line_id in DB.line_order:
		var line: Dictionary = DB.lines[line_id]
		for sid in line["order"]:
			if line["stations"][sid]["name"] == sname:
				var lines_arr: Array = []
				for lid2 in DB.line_order:
					var l2: Dictionary = DB.lines[lid2]
					for sid2 in l2["order"]:
						if l2["stations"][sid2]["name"] == sname:
							lines_arr.append(str(l2["short"]))
							break
				var stops_n := 0
				for tr in DB.trains:
					for stop in tr["stops"]:
						if str(stop.get("name", "")) == sname:
							stops_n += 1
							break
				station_card.show_station(sname, lines_arr, int(line["stations"][sid]["km"]), stops_n,
						bool(line["stations"][sid]["major"]))
				return


func _build_global_search() -> void:
	global_search = GlobalSearch.new()
	global_search.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 12)
	global_search.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ui_root.add_child(global_search)
	global_search.train_picked.connect(func(code: String):
		diagram.visible = false
		line_screen.visible = false
		train_search_picked.emit(code))
	global_search.station_picked.connect(func(sname: String):
		open_station_by_name(sname))
	global_search.line_picked.connect(func(line_id: String):
		line_screen.open(line_id))


func _on_spot_mode(on: bool) -> void:
	spot_pill.visible = on
	var sb := ui_root.find_child("SpotButton", true, false)
	if sb != null:
		sb.set_pressed_no_signal(on)


func _on_aviation_changed() -> void:
	var air_ok: bool = FlightSim.ready_ok
	if Meta.aviation_on and air_ok:
		show_toast("✈ 航空视图：%d 机场 · %d 航线 · 日航班 %d 班，点击飞机/机场查看详情（F8 切回铁路）" % [
			FlightSim.airport_list.size(), FlightSim.routes.size(), FlightSim.flights.size()])
	elif Meta.aviation_on and not air_ok:
		show_toast("航空数据未就绪（data/air/aviation.json 缺失）")
	elif air_ok:
		show_toast("🛤 铁路视图（F8 切换航空）")
	# 视图归属：图例/打卡横幅/小地图属铁路，航空视图收起
	legend_panel.visible = not Meta.aviation_on
	mini_map.visible = not Meta.aviation_on
	if Meta.aviation_on:
		checkin_pill.visible = false
	var ab := ui_root.find_child("AirButton", true, false)
	if ab != null:
		ab.set_pressed_no_signal(Meta.aviation_on)
		ab.text = "🛤 铁路视图 [F8]" if Meta.aviation_on else "✈ 航空视图 [F8]"


func close_flight_cards() -> void:
	flight_card.visible = false
	airport_card.visible = false


func toast(title: String, body: String, accent: Color = UIKit.ACCENT2) -> void:
	var pc := UIKit.panel_container(UIKit.flat(Color("1a2230f0"), 10, accent, 1, 12))
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l1 := UIKit.label(title, 14, accent)
	var l2 := UIKit.label(body, 12, UIKit.TEXT)
	l2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l2.custom_minimum_size = Vector2(250, 0)
	vb.add_child(l1)
	vb.add_child(l2)
	pc.add_child(vb)
	toast_box.add_child(pc)
	pc.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(pc, "modulate:a", 1.0, 0.18)
	tw.tween_interval(3.8)
	tw.tween_property(pc, "modulate:a", 0.0, 0.45)
	tw.tween_callback(pc.queue_free)


func set_follow_pill(text: String) -> void:
	if text == "":
		follow_pill.visible = false
	else:
		follow_pill.visible = true
		follow_label.text = text


func any_overlay_open() -> bool:
	return dex.visible or ach_screen.visible or help_panel.visible 			or diagram.visible or line_screen.visible 			or checkin_book.visible 			or yard_view.visible


func close_overlays() -> void:
	dex.visible = false
	ach_screen.visible = false
	help_panel.visible = false
	diagram.visible = false
	line_screen.visible = false
	checkin_book.visible = false
	yard_view.visible = false


func toggle_list() -> void:
	train_list.toggle()


func toggle_dex() -> void:
	ach_screen.visible = false
	help_panel.visible = false
	dex.toggle()


func toggle_diagram() -> void:
	ach_screen.visible = false
	help_panel.visible = false
	diagram.toggle()


func toggle_ach() -> void:
	dex.visible = false
	help_panel.visible = false
	ach_screen.toggle()


func toggle_help() -> void:
	dex.visible = false
	ach_screen.visible = false
	help_panel.visible = not help_panel.visible

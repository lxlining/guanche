# 主 UI 外壳：时钟、时间控制条、顶部按钮、跟随/机位提示、成就弹窗、帮助与各子界面。
extends CanvasLayer

signal train_search_picked(code: String)
signal cam_jump_requested(world_pos: Vector2)

const UIKit := preload("res://src/ui/ui_kit.gd")
const FontLib := preload("res://src/ui/font_lib.gd")
const TrainList := preload("res://src/ui/train_list.gd")
const DetailCard := preload("res://src/ui/detail_card.gd")
const DexScreen := preload("res://src/ui/dex_screen.gd")
const AchievementsScreen := preload("res://src/ui/achievements_screen.gd")
const DiagramView := preload("res://src/ui/diagram_view.gd")
const StationCard := preload("res://src/ui/station_card.gd")
const LineScreen := preload("res://src/ui/line_screen.gd")
const GlobalSearch := preload("res://src/ui/global_search.gd")
const MiniMap := preload("res://src/ui/mini_map.gd")

var ui_root: Control
var clock_label: Label
var clock_sub: Label
var follow_pill: PanelContainer
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
	line_screen = LineScreen.new()
	ui_root.add_child(line_screen)
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


func _build_legend() -> void:
	var p := UIKit.panel_container(UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 10))
	p.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	p.grow_vertical = Control.GROW_DIRECTION_BOTH
	ui_root.add_child(p)
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
	hb.add_child(UIKit.button("车型图鉴 [D]", func(): toggle_dex()))
	hb.add_child(UIKit.button("成就 [A]", func(): toggle_ach()))
	var spot_btn := UIKit.button("机位模式 [P]", func(): Meta.toggle_spot_mode())
	spot_btn.name = "SpotButton"
	hb.add_child(spot_btn)
	hb.add_child(UIKit.button("帮助 [F1]", func(): toggle_help()))


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

func _process(_delta: float) -> void:
	if clock_label != null:
		clock_label.text = ("Ⅱ " if GameTime.paused else "") + GameTime.time_string_full()
		clock_sub.text = "%s× · %d 条线路 · %d 站 · 在图 %d 趟" % [
			_fmt_speed(GameTime.speed), DB.line_order.size(), DB.total_station_count(), _active_count()]


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


func _on_focus_changed() -> void:
	if Meta.focus_line == "":
		focus_pill.visible = false
	else:
		focus_pill.visible = true
		focus_label.text = "线路专注：%s · 点击其他线路切换 · [Esc] 退出" % DB.line(Meta.focus_line)["short"]


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
	return dex.visible or ach_screen.visible or help_panel.visible 			or diagram.visible or line_screen.visible


func close_overlays() -> void:
	dex.visible = false
	ach_screen.visible = false
	help_panel.visible = false
	diagram.visible = false
	line_screen.visible = false


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

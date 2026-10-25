# 时刻-距离运行图叠加层：所选线路的全部列车按「到发时刻 × 里程」画成斜线，
# 红色竖线为当前时刻游标（可左右拖动平移时间），点击车次线选中列车。
# 纵轴用车站官方里程（真实公里标），斜线在站间取直线（传统运行图画法）。
# 右上角可切换线路（各线里程体系独立）。
extends Control

const UIKit := preload("res://src/ui/ui_kit.gd")
const FontLib := preload("res://src/ui/font_lib.gd")

signal train_picked(code: String)

var selected := ""
var hover := ""
var cur_line := ""

var _scrubbing := false
var _mouse := Vector2.ZERO
const MARGIN_L := 104.0
const MARGIN_R := 30.0
const MARGIN_T := 46.0
const MARGIN_B := 30.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	cur_line = "jinghu_hsr" if DB.lines.has("jinghu_hsr") else DB.line_order[0]

	var selector := OptionButton.new()
	var default_idx := 0
	for i in range(DB.line_order.size()):
		var line_id: String = DB.line_order[i]
		selector.add_item(DB.lines[line_id]["short"])
		selector.set_item_metadata(i, line_id)
		if line_id == cur_line:
			default_idx = i
	selector.item_selected.connect(func(idx: int):
		cur_line = str(selector.get_item_metadata(idx))
		queue_redraw())
	selector.select(default_idx)
	selector.add_theme_font_size_override("font_size", 12)
	selector.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 10)
	selector.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_child(selector)


func toggle() -> void:
	visible = not visible
	if visible:
		queue_redraw()


func set_selected(code: String) -> void:
	selected = code
	if visible:
		queue_redraw()


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _line() -> Dictionary:
	return DB.line(cur_line)


func _km_max() -> float:
	var line: Dictionary = _line()
	var order: Array = line["order"]
	return float(line["stations"][order[order.size() - 1]]["km"])


func _plot_rect() -> Rect2:
	return Rect2(MARGIN_L, MARGIN_T, maxf(size.x - MARGIN_L - MARGIN_R, 100.0),
			maxf(size.y - MARGIN_T - MARGIN_B, 100.0))


func _x_of(t: float, pr: Rect2) -> float:
	return pr.position.x + fposmod(t, 86400.0) / 86400.0 * pr.size.x


func _y_of(km: float, pr: Rect2) -> float:
	return pr.position.y + pr.size.y * (1.0 - clampf(km, 0.0, _km_max()) / _km_max())


# 每趟车在所选线路上的折线段：按腿取点，跨午夜处断开（传统运行图画法）
func _train_segs(train: Dictionary, pr: Rect2) -> Array:
	var segs: Array = []
	for leg in train["legs"]:
		if str(leg["line"]) != cur_line:
			continue
		var pts := PackedVector2Array()
		var prev_x := -1.0e18
		var lst: Array = leg["stops"]
		var m := lst.size()
		for i in range(m):
			var km: float = float(_line()["stations"][lst[i]["sid"]]["km"])
			var y := _y_of(km, pr)
			var x: float
			if i == 0:
				x = _x_of(lst[i]["dep_s"], pr)
			elif i == m - 1:
				x = _x_of(lst[i]["arr_s"], pr)
			else:
				x = _x_of(lst[i]["dep_s"], pr)
			if x < prev_x - pr.size.x * 0.5:
				if pts.size() >= 2:
					segs.append(pts)
				pts = PackedVector2Array()
				prev_x = -1.0e18
			if pts.size() == 0 or x >= prev_x:
				pts.append(Vector2(x, y))
				prev_x = x
		if pts.size() >= 2:
			segs.append(pts)
	return segs


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0
	var l2 := ab.length_squared()
	if l2 > 0.0001:
		t = clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _pick_at(pos: Vector2) -> String:
	var pr := _plot_rect()
	if not pr.grow(20.0).has_point(pos):
		return ""
	var best := ""
	var best_d := 7.0
	for train in DB.trains:
		if train["line"] != cur_line:
			continue
		for pts in _train_segs(train, pr):
			for i in range(pts.size() - 1):
				var d := _seg_dist(pos, pts[i], pts[i + 1])
				if d < best_d:
					best_d = d
					best = train["code"]
	return best


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var pr := _plot_rect()
			var cursor_x := _x_of(GameTime.t, pr)
			if absf(event.position.x - cursor_x) < 10.0:
				_scrubbing = true
			else:
				train_picked.emit(_pick_at(event.position))
		else:
			_scrubbing = false
	elif event is InputEventMouseMotion:
		_mouse = event.position
		if _scrubbing:
			var pr := _plot_rect()
			var t: float = (event.position.x - pr.position.x) / pr.size.x * 86400.0
			GameTime.jump_to_seconds(clampf(t, 0.0, 86399.0))
		else:
			var h := _pick_at(event.position)
			if h != hover:
				hover = h
				queue_redraw()


func _draw() -> void:
	var font := FontLib.get_font()
	var pr := _plot_rect()
	var line: Dictionary = _line()

	draw_rect(Rect2(Vector2.ZERO, size), Color(0.045, 0.055, 0.08, 0.97))

	# 小时网格
	for h in range(0, 25):
		var x := _x_of(h * 3600.0, pr)
		draw_line(Vector2(x, pr.position.y), Vector2(x, pr.position.y + pr.size.y),
				Color(1, 1, 1, 0.05), 1.0)
		draw_string(font, Vector2(x - 20, pr.position.y + pr.size.y + 18),
				"%02d:00" % (h % 24), HORIZONTAL_ALIGNMENT_CENTER, 40, 11, UIKit.DIM)
	# 车站横线与站名
	for sid in line["order"]:
		var st: Dictionary = line["stations"][sid]
		var y := _y_of(float(st["km"]), pr)
		var major: bool = st["major"]
		draw_line(Vector2(pr.position.x, y), Vector2(pr.position.x + pr.size.x, y),
				Color(1, 1, 1, 0.09 if major else 0.045), 1.0)
		draw_string(font, Vector2(10, y + 4), "K%d" % int(st["km"]),
				HORIZONTAL_ALIGNMENT_LEFT, 34, 9, Color(0.5, 0.56, 0.66))
		draw_string(font, Vector2(48, y + 4), str(st["name"]), HORIZONTAL_ALIGNMENT_LEFT,
				60, 11 if major else 10, UIKit.TEXT if major else Color(0.6, 0.66, 0.76))

	# 列车斜线（先普通后高亮）
	for train in DB.trains:
		if train["line"] != cur_line:
			continue
		var code: String = train["code"]
		if code == selected or code == hover:
			continue
		var tt: Dictionary = DB.train_types.get(train["type"], {})
		var col: Color = Color(tt.get("color", "#8fa3b8"))
		col.a = 0.35
		for pts in _train_segs(train, pr):
			_draw_line_pts(pts, col, 1.2)
	if hover != "" and hover != selected and DB.train_by_code[hover]["line"] == cur_line:
		for pts in _train_segs(DB.train_by_code[hover], pr):
			_draw_line_pts(pts, Color(1, 1, 1, 0.75), 2.0)
	if selected != "" and DB.train_by_code[selected]["line"] == cur_line:
		for pts in _train_segs(DB.train_by_code[selected], pr):
			_draw_line_pts(pts, Color.WHITE, 2.6)

	# 当前时刻游标
	var cx := _x_of(GameTime.t, pr)
	draw_line(Vector2(cx, pr.position.y), Vector2(cx, pr.position.y + pr.size.y),
			Color(0.95, 0.35, 0.35, 0.9), 1.6)
	draw_rect(Rect2(cx - 26, 10, 52, 22), Color(0.5, 0.13, 0.13, 0.9))
	draw_string(font, Vector2(cx - 26, 25), GameTime.time_string(),
			HORIZONTAL_ALIGNMENT_CENTER, 52, 13, Color.WHITE)
	# 每趟在线列车在游标上的当前位置
	for code in Simulation.states:
		var st: Dictionary = Simulation.states[code]
		if str(st.get("line", "")) != cur_line:
			continue
		var s: String = st.get("status", "off")
		if s != "run" and s != "stop" and s != "wait":
			continue
		var col: Color = Color(DB.train_types.get(st["type"], {}).get("color", "#8fa3b8"))
		var pos := Vector2(cx, _y_of(float(st.get("km", 0.0)), pr))
		if code == selected:
			draw_circle(pos, 4.2, Color.WHITE)
			draw_arc(pos, 6.5, 0, TAU, 20, Color(1, 1, 1, 0.5), 1.2, true)
		else:
			draw_circle(pos, 2.4, col.lightened(0.2))

	draw_string(font, Vector2(MARGIN_L, 30),
			"运行图（时刻-距离图）· 右上角切换线路 · 拖动红色游标平移时刻 · 点击斜线选中列车 · [G] 关闭",
			HORIZONTAL_ALIGNMENT_LEFT, 900, 12, UIKit.DIM)


func _draw_line_pts(pts: PackedVector2Array, col: Color, w: float) -> void:
	if pts.size() >= 2:
		draw_polyline(pts, col, w, true)

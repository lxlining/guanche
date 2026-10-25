# 车型侧视图「模型图」：按编组数与涂装色程序化绘制动车组侧影
# （流线鼻、车窗带、车门、转向架、受电弓、涂装腰线）。
# 若存在 data/trains/images/<车型id>.png 则优先显示该图片（用户可自行放置实拍图）。
extends Control

const IMG_DIR := "res://data/trains/images/"

static var _tex_cache := {}

var _type: Dictionary = {}
var _type_id := ""


func setup(tt: Dictionary, height: float = 72.0) -> void:
	_type = tt
	_type_id = str(tt.get("id", ""))
	custom_minimum_size = Vector2(0, height)
	size.y = height
	queue_redraw()


func _tex() -> Texture2D:
	if _type_id == "":
		return null
	if not _tex_cache.has(_type_id):
		var path := IMG_DIR + _type_id + ".png"
		var t: Texture2D = null
		if FileAccess.file_exists(path):
			t = load(path) as Texture2D
		_tex_cache[_type_id] = t
	return _tex_cache[_type_id]


func _draw() -> void:
	var s := size
	if s.x < 40.0 or s.y < 30.0:
		return
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.05, 0.07, 0.11, 0.85))
	var tex := _tex()
	if tex != null:
		var tr := tex.get_size()
		if tr.x > 0.0 and tr.y > 0.0:
			var k: float = minf((s.x - 8.0) / tr.x, (s.y - 8.0) / tr.y)
			var d := tr * k
			draw_texture_rect(tex, Rect2((s - d) * 0.5, d), false)
		return
	_draw_schematic(s)


func _cars() -> int:
	var acc := ""
	for ch in str(_type.get("formation", "8")):
		if ch >= "0" and ch <= "9":
			acc += ch
		elif acc != "":
			break
	return clampi(int(acc) if acc != "" else 8, 2, 17)


func _draw_schematic(s: Vector2) -> void:
	var col: Color = Color(str(_type.get("color", "#8fa3b8")))
	var body := col.lightened(0.35) if col.get_luminance() < 0.30 else col
	var dark := Color(0.07, 0.09, 0.13)
	var n := _cars()
	var margin := 12.0
	var rail_y := s.y - 11.0
	var car_h := clampf(s.y * 0.44, 12.0, 32.0)
	var top := rail_y - car_h - 5.0
	var usable := s.x - margin * 2.0
	var gap := 2.0
	var car_w := (usable - gap * (n - 1)) / n

	# 钢轨
	draw_line(Vector2(margin - 6, rail_y + 2), Vector2(s.x - margin + 6, rail_y + 2),
			Color(0.30, 0.36, 0.45), 1.5)

	var body_sb := StyleBoxFlat.new()
	body_sb.bg_color = body
	body_sb.set_corner_radius_all(2)
	var win_sb := StyleBoxFlat.new()
	win_sb.bg_color = dark
	win_sb.set_corner_radius_all(1)

	var nose := car_w * 0.34
	for i in range(n):
		var x := margin + i * (car_w + gap)
		var r := Rect2(x, top, car_w, car_h)
		var lead := i == 0 or i == n - 1
		if lead and n >= 3:
			var p := PackedVector2Array()
			if i == 0:
				p = PackedVector2Array([
					r.position + Vector2(nose, 0), r.position + Vector2(car_w, 0),
					r.position + Vector2(car_w, car_h), r.position + Vector2(0, car_h),
					r.position + Vector2(0, car_h * 0.55)])
			else:
				p = PackedVector2Array([
					r.position, r.position + Vector2(car_w - nose, 0),
					r.position + Vector2(car_w, car_h * 0.55),
					r.position + Vector2(car_w, car_h), r.position])
			draw_colored_polygon(p, body)
		else:
			draw_rect(r, body)

		# 车窗带（端车避开流线鼻）
		var strip := Rect2(r.position.x + car_w * 0.14, top + car_h * 0.16,
				car_w * 0.72, car_h * 0.26)
		if i == 0 and n >= 3:
			strip = Rect2(r.position.x + nose * 1.1, top + car_h * 0.18,
					car_w - nose * 1.35, car_h * 0.26)
		elif i == n - 1 and n >= 3:
			strip = Rect2(r.position.x + car_w * 0.14, top + car_h * 0.18,
					car_w - nose * 1.35, car_h * 0.26)
		draw_style_box(win_sb, strip)

		# 车门
		var door_w := maxf(car_w * 0.06, 1.5)
		draw_rect(Rect2(r.position.x + car_w * 0.09, top + car_h * 0.16, door_w,
				car_h * 0.62), dark)
		draw_rect(Rect2(r.position.x + car_w * 0.91 - door_w, top + car_h * 0.16,
				door_w, car_h * 0.62), dark)

		# 转向架与车轮
		for bx in [0.20, 0.62]:
			var wx: float = x + car_w * bx
			draw_rect(Rect2(wx, rail_y - 4.0, car_w * 0.18, 4.0), dark)
			draw_circle(Vector2(wx + car_w * 0.09, rail_y + 1.0),
					minf(2.6, car_h * 0.13), dark)

	# 受电弓（第 2 节与倒数第 2 节）
	for i in [1, n - 2]:
		if i <= 0 or i >= n - 1:
			continue
		var x: float = margin + i * (car_w + gap) + car_w * 0.5
		var y0 := top - 3.0
		draw_polyline(PackedVector2Array([Vector2(x - 5, y0 + 6), Vector2(x, y0),
				Vector2(x + 5, y0 + 6)]), dark, 1.2)
		draw_line(Vector2(x - 6, y0 + 6.5), Vector2(x + 6, y0 + 6.5), dark, 1.2)

	# 涂装腰线
	draw_line(Vector2(margin, top + car_h * 0.60), Vector2(s.x - margin, top + car_h * 0.60),
			Color(1, 1, 1, 0.45), 1.2)

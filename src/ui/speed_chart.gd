# 速度曲线图：显示列车全程区段速度变化（距离-速度折线图）。
# 在详情卡中展示，让用户直观看到加速/巡航/减速/停站模式。
extends Control

var stops: Array = []      # [{sid, name, arr_s, dep_s, arc, line}]
var line_data: Dictionary = {}  # line_id -> {station_arc, total}
var train := {}

const COL_BG := Color(0.04, 0.06, 0.10, 0.7)
const COL_LINE := Color(0.4, 0.6, 1.0, 0.8)
const COL_FILL := Color(0.3, 0.5, 1.0, 0.12)
const COL_STOP := Color(1.0, 0.7, 0.3, 0.8)
const COL_TEXT := Color(0.5, 0.55, 0.65)


func setup(tr: Dictionary) -> void:
	train = tr
	stops = tr.get("stops", [])
	queue_redraw()


func _draw() -> void:
	if stops.size() < 2 or train.is_empty():
		return
	var s := size
	if s.x < 30 or s.y < 30:
		return
	draw_rect(Rect2(Vector2.ZERO, s), COL_BG)

	var margin_l := 30.0
	var margin_r := 8.0
	var margin_t := 6.0
	var margin_b := 16.0
	var pw := s.x - margin_l - margin_r
	var ph := s.y - margin_t - margin_b

	# 计算总里程和最高速度
	var total_km := 0.0
	var max_speed := 0.0
	var segments: Array = []  # {km0, km1, speed}
	var line_data = {}
	for leg in train.get("legs", []):
		var lid: String = leg["line"]
		var line: Dictionary = DB.line(lid)
		var arc_st: Dictionary = line["station_arc"]
		for k in range(leg["stops"].size() - 1):
			var s0: Dictionary = leg["stops"][k]
			var s1: Dictionary = leg["stops"][k + 1]
			var arc0: float = float(s0["arc"])
			var arc1: float = float(s1["arc"])
			var len_m: float = absf(arc1 - arc0)
			var dur: float = s1["arr_s"] - s0["dep_s"]
			if dur <= 0 or len_m <= 0:
				continue
			var speed := len_m / dur * 3.6
			var km0: float = _km_for(lid, s0["sid"])
			var km1: float = _km_for(lid, s1["sid"])
			segments.append({"km0": km0, "km1": km1, "speed": speed})
			max_speed = maxf(max_speed, speed)
			total_km = maxf(total_km, maxf(km0, km1))
	if total_km <= 0 or max_speed <= 0:
		return
	max_speed = clampf(max_speed, 100.0, 400.0)

	# 网格线（每 100km/h）
	for sv in range(0, 401, 100):
		var y := margin_t + ph * (1.0 - float(sv) / 400.0)
		draw_line(Vector2(margin_l, y), Vector2(s.x - margin_r, y),
				Color(1, 1, 1, 0.06), 1.0)
		draw_string(ThemeDB.fallback_font, Vector2(2, y + 3), "%d" % sv,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, COL_TEXT)

	# 速度折线
	var pts := PackedVector2Array()
	for seg in segments:
		var x0: float = margin_l + (float(seg["km0"]) / total_km) * pw
		var x1: float = margin_l + (float(seg["km1"]) / total_km) * pw
		var y0: float = margin_t + ph * (1.0 - float(seg["speed"]) / 400.0)
		pts.append(Vector2(x0, y0))
		pts.append(Vector2(x1, y0))
		# 填充
		draw_line(Vector2(x0, y0), Vector2(x1, y0), COL_LINE, 1.5)
	if pts.size() >= 2:
		var fill := pts.duplicate()
		fill.append(Vector2(pts[pts.size()-1].x, margin_t + ph))
		fill.insert(0, Vector2(pts[0].x, margin_t + ph))
		draw_colored_polygon(fill, COL_FILL)
		draw_polyline(pts, COL_LINE, 1.5, true)

	# 停站标记
	for seg in segments:
		for km_val in [seg["km0"], seg["km1"]]:
			var x: float = margin_l + (float(km_val) / total_km) * pw
			draw_line(Vector2(x, margin_t + ph - 3), Vector2(x, margin_t + ph),
					COL_STOP, 2.0)

	# 里程标尺
	draw_string(ThemeDB.fallback_font, Vector2(margin_l, s.y - 3),
			"K0", HORIZONTAL_ALIGNMENT_LEFT, -1, 8, COL_TEXT)
	draw_string(ThemeDB.fallback_font, Vector2(s.x - margin_r - 20, s.y - 3),
			"K%d" % int(total_km), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, COL_TEXT)


func _km_for(line_id: String, sid: String) -> float:
	var line: Dictionary = DB.line(line_id)
	if line["stations"].has(sid):
		return float(line["stations"][sid]["km"])
	return 0.0

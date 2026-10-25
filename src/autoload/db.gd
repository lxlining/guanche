# 数据总线（多线路版）：加载全部线路/底图/车型/时刻表/成就。
# 每条线路独立维护站表、几何与弧长体系；列车汇总时携带所属线路 id。
extends Node

const GeoScript := preload("res://src/core/geo.gd")
const GameTimeScript := preload("res://src/autoload/game_time.gd")

var lines: Dictionary = {}        # line_id -> LineData
var line_order: Array = []        # [line_id, ...]（加载顺序即地图图层顺序）
var trains: Array = []            # 全部列车汇总（train["line"] = line_id）
var train_by_code: Dictionary = {}
var express_codes: Array = []     # 大站车（成就用）

var background: Dictionary = {}
var train_types: Dictionary = {}
var type_list: Array = []
var achievements: Array = []
var data_warnings: Array = []

# 三线联合视野（相机初始 fit 用）
var map_center: Vector2 = Vector2.ZERO
var map_size: Vector2 = Vector2.ONE
var fit_zoom: float = 0.001


func _ready() -> void:
	background = _load_json("res://data/map/background.json")
	var types_doc := _load_json("res://data/trains/train_types.json")
	var ach_doc := _load_json("res://data/achievements.json")
	for t in types_doc.get("types", []):
		train_types[t["id"]] = t
		type_list.append(t)
	achievements = ach_doc.get("achievements", [])

	_load_lines()
	_build_background()
	_load_trains()
	_union_bounds()

	for w in data_warnings:
		push_warning("DB: " + w)


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		data_warnings.append("缺少文件 " + path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		data_warnings.append("无法打开 " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		data_warnings.append("JSON 解析失败 " + path)
		return {}
	return parsed


func _load_lines() -> void:
	var dir := DirAccess.open("res://data/lines")
	if dir == null:
		data_warnings.append("无法读取 data/lines 目录")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			var doc := _load_json("res://data/lines/" + fname)
			if not doc.is_empty() and doc.has("id") and doc.has("stations"):
				lines[doc["id"]] = _build_line(doc)
				line_order.append(doc["id"])
		fname = dir.get_next()
	dir.list_dir_end()
	print("DB: 已加载 %d 条线路" % line_order.size())


func _build_line(doc: Dictionary) -> Dictionary:
	var line := {
		"id": doc["id"], "name": doc.get("name", doc["id"]),
		"short": doc.get("short", doc["id"]), "color": Color(doc.get("color", "#6272e0")),
		"from": doc.get("from", ""), "to": doc.get("to", ""),
		"stations": {}, "order": [], "geometry_pts": [],
		"cum": PackedFloat64Array(), "total_len_m": 0.0,
		"station_arc": {}, "arc_marks": [],
		"center": Vector2.ZERO, "size": Vector2.ONE, "fit_zoom": 0.001
	}
	for s in doc.get("stations", []):
		line["stations"][s["id"]] = {
			"id": s["id"], "name": s["name"],
			"lon": float(s["lon"]), "lat": float(s["lat"]),
			"km": float(s["km"]), "major": bool(s.get("major", false)),
			"pos": GeoScript.lonlat_to_world(float(s["lon"]), float(s["lat"]))
		}
		line["order"].append(s["id"])

	var min_p := Vector2.INF
	var max_p := -Vector2.INF
	for g in doc.get("geometry", []):
		var pos: Vector2 = GeoScript.lonlat_to_world(float(g[0]), float(g[1]))
		line["geometry_pts"].append({"pos": pos, "station": g[2] if g.size() > 2 and g[2] != null else ""})
		min_p = min_p.min(pos)
		max_p = max_p.max(pos)

	var cum: PackedFloat64Array = line["cum"]
	cum.resize(line["geometry_pts"].size())
	cum[0] = 0.0
	var pts: Array = line["geometry_pts"]
	for i in range(1, pts.size()):
		cum[i] = cum[i - 1] + pts[i - 1]["pos"].distance_to(pts[i]["pos"])
	line["total_len_m"] = cum[cum.size() - 1]

	for p in pts:
		if p["station"] != "":
			line["station_arc"][p["station"]] = cum[pts.find(p)]

	var marks: Array = line["arc_marks"]
	for sid in line["order"]:
		marks.append({"sid": sid, "arc": line["station_arc"][sid], "km": line["stations"][sid]["km"]})
	marks.sort_custom(func(a, b): return a["arc"] < b["arc"])

	for i in range(line["order"].size()):
		var sid: String = line["order"][i]
		if absf(line["station_arc"][sid] - marks[i]["arc"]) > 1.0:
			data_warnings.append("线路 %s 几何点顺序与站序不一致" % line["id"])
			break

	line["center"] = (min_p + max_p) * 0.5
	line["size"] = max_p - min_p
	line["fit_zoom"] = minf(1500.0 / maxf(line["size"].x, 1.0), 830.0 / maxf(line["size"].y, 1.0))
	return line


func _load_trains() -> void:
	var doc := _load_json("res://data/timetables/all.json")
	if doc.is_empty():
		data_warnings.append("缺少 data/timetables/all.json（运行 tools/build_from_12306.py 生成）")
		return
	var per_line: Dictionary = doc.get("lines", {})
	for line_id in line_order:
		var linedoc: Dictionary = per_line.get(line_id, {})
		for tr in linedoc.get("trains", []):
			var train := _parse_train(tr, line_id)
			if train.is_empty():
				continue
			trains.append(train)
			train_by_code[train["code"]] = train
			if train.get("express", false):
				express_codes.append(train["code"])

	trains.sort_custom(func(a, b): return a["start_s"] < b["start_s"])
	print("DB: 已加载 %d 条线路、%d 趟列车" % [line_order.size(), trains.size()])


func _parse_train(tr: Dictionary, line_id: String) -> Dictionary:
	var code: String = tr.get("code", "")
	if code == "" or not tr.has("stops") or tr["stops"].size() < 2:
		data_warnings.append("车次数据不完整：%s" % code)
		return {}
	var line: Dictionary = lines[line_id]
	var stops_raw: Array = tr["stops"]
	var stops: Array = []
	var offset := 0.0
	var prev_abs := -1.0
	for i in range(stops_raw.size()):
		var sr: Dictionary = stops_raw[i]
		var sid: String = sr["sid"]
		if not line["stations"].has(sid):
			data_warnings.append("%s 引用线路 %s 未知车站 %s" % [code, line_id, sid])
			return {}
		var arr_s := -1.0
		var dep_s := -1.0
		if sr.has("arr") and sr["arr"] != null:
			arr_s = GameTimeScript.parse_hhmm(sr["arr"]) + offset
			if arr_s < prev_abs:
				offset += 86400.0
				arr_s += 86400.0
			prev_abs = arr_s
		if sr.has("dep") and sr["dep"] != null:
			dep_s = GameTimeScript.parse_hhmm(sr["dep"]) + offset
			if dep_s < prev_abs:
				offset += 86400.0
				dep_s += 86400.0
			prev_abs = dep_s
		if arr_s < 0.0:
			arr_s = dep_s
		if dep_s < 0.0:
			dep_s = arr_s
		stops.append({
			"sid": sid, "arr_s": arr_s, "dep_s": dep_s,
			"arc": float(line["station_arc"][sid])
		})

	var start_s: float = stops[0]["dep_s"]
	var end_s: float = stops[stops.size() - 1]["arr_s"]
	if end_s <= start_s:
		data_warnings.append("%s 时刻非单调" % code)
		return {}

	var segs: Array = []
	for i in range(stops.size()):
		stops[i]["arr_rel"] = stops[i]["arr_s"] - start_s
		stops[i]["dep_rel"] = stops[i]["dep_s"] - start_s
		if i > 0:
			var arc0: float = stops[i - 1]["arc"]
			var arc1: float = stops[i]["arc"]
			var dur: float = stops[i]["arr_s"] - stops[i - 1]["dep_s"]
			segs.append({
				"arc0": arc0, "arc1": arc1,
				"len_m": absf(arc1 - arc0),
				"dur_s": dur,
				"accel": clampf(6000.0 / maxf(absf(arc1 - arc0), 1.0), 0.04, 0.25)
			})

	var pass_counts: Array = []
	var order: Array = line["order"]
	for i in range(stops.size() - 1):
		var i0 := order.find(stops[i]["sid"])
		var i1 := order.find(stops[i + 1]["sid"])
		pass_counts.append(absi(i1 - i0) - 1)

	return {
		"code": code,
		"line": line_id,
		"type": tr.get("type", "CR400AF"),
		"dir": "down" if stops[0]["sid"] == order[0] else "up",
		"from": tr.get("from", line["stations"][stops[0]["sid"]]["name"]),
		"to": tr.get("to", line["stations"][stops[stops.size() - 1]["sid"]]["name"]),
		"off_map": bool(tr.get("off_map", false)),
		"express": bool(tr.get("express", false)),
		"generated": bool(tr.get("generated", false)),
		"stops": stops,
		"segs": segs,
		"pass_counts": pass_counts,
		"start_s": start_s,
		"end_s": end_s,
		"run_dur": end_s - start_s
	}


func _union_bounds() -> void:
	var min_p := Vector2.INF
	var max_p := -Vector2.INF
	for line_id in line_order:
		var line: Dictionary = lines[line_id]
		for p in line["geometry_pts"]:
			var pos: Vector2 = p["pos"]
			min_p = min_p.min(pos)
			max_p = max_p.max(pos)
	map_center = (min_p + max_p) * 0.5
	map_size = max_p - min_p
	fit_zoom = minf(1500.0 / maxf(map_size.x, 1.0), 830.0 / maxf(map_size.y, 1.0))


# ---------- 几何查询（per line） ----------

func line(id: String) -> Dictionary:
	if lines.has(id):
		return lines[id]
	return lines[line_order[0]]


func arc_point(line_id: String, arc: float) -> Dictionary:
	var line: Dictionary = line(line_id)
	var cum: PackedFloat64Array = line["cum"]
	var a := clampf(arc, 0.0, line["total_len_m"])
	var lo := 0
	var hi := cum.size() - 1
	while lo < hi - 1:
		var mid := (lo + hi) >> 1
		if cum[mid] <= a:
			lo = mid
		else:
			hi = mid
	var seg_len := cum[hi] - cum[lo]
	var f: float = 0.0 if seg_len <= 0.0 else (a - cum[lo]) / seg_len
	var pts: Array = line["geometry_pts"]
	var pa: Vector2 = pts[lo]["pos"]
	var pb: Vector2 = pts[hi]["pos"]
	var dir := (pb - pa).normalized() if seg_len > 1.0 else Vector2.RIGHT
	return {"pos": pa.lerp(pb, f), "dir": dir}


func km_at_arc(line_id: String, arc: float) -> int:
	var line: Dictionary = line(line_id)
	var marks: Array = line["arc_marks"]
	if marks.is_empty():
		return 0
	if arc <= marks[0]["arc"]:
		return int(marks[0]["km"])
	for i in range(1, marks.size()):
		if arc <= marks[i]["arc"]:
			var m0: Dictionary = marks[i - 1]
			var m1: Dictionary = marks[i]
			var span: float = m1["arc"] - m0["arc"]
			var f: float = 0.0 if span <= 0.0 else (arc - m0["arc"]) / span
			return int(round(lerpf(m0["km"], m1["km"], f)))
	return int(marks[marks.size() - 1]["km"])


func nearest_station(line_id: String, pos: Vector2, max_dist_m: float = 1.0e9) -> String:
	var line: Dictionary = line(line_id)
	var best := ""
	var best_d := max_dist_m
	for sid in line["order"]:
		var d: float = pos.distance_to(line["stations"][sid]["pos"])
		if d < best_d:
			best_d = d
			best = sid
	return best


func station_name(line_id: String, sid: String) -> String:
	var line: Dictionary = line(line_id)
	var st: Dictionary = line["stations"].get(sid, {})
	return str(st.get("name", sid))


func total_station_count() -> int:
	var n := 0
	for line_id in line_order:
		n += lines[line_id]["order"].size()
	return n

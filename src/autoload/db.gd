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
	_build_name_pos()
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
		"line_class": doc.get("line_class", "hsr250"),
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
	for tr in doc.get("trains", []):
		var line_id: String = str(tr.get("line", ""))
		if not lines.has(line_id):
			continue
		var train := _parse_train(tr, line_id)
		if train.is_empty():
			continue
		trains.append(train)
		train_by_code[train["code"]] = train
		if train.get("express", false):
			express_codes.append(train["code"])

	# 货运示意车流（独立文件）
	var fdoc := _load_json("res://data/timetables/freight.json")
	for tr in fdoc.get("trains", []):
		var flid: String = str(tr.get("line", ""))
		if not lines.has(flid):
			continue
		var ftrain := _parse_train(tr, flid)
		if ftrain.is_empty():
			continue
		ftrain["freight"] = true
		ftrain["note"] = str(tr.get("note", ""))
		trains.append(ftrain)
		train_by_code[ftrain["code"]] = ftrain

	trains.sort_custom(func(a, b): return a["start_s"] < b["start_s"])
	print("DB: 已加载 %d 条线路、%d 趟列车（含货运示意）" % [line_order.size(), trains.size()])


func _parse_train(tr: Dictionary, line_id: String) -> Dictionary:
	# line_id = 主线（最长腿所属，列表统计/筛选用）。
	# 列车按真实路径跨线运行：legs 为同一线路上连续停站的区段（腿），
	# 腿间通过 transfer（联络/跨线移动）衔接；网外首末站标记 off_map。
	var code: String = tr.get("code", "")
	var stops_raw: Array = tr.get("stops", [])
	var legs_raw: Array = tr.get("legs", [])
	if code == "" or stops_raw.size() < 2 or legs_raw.is_empty():
		data_warnings.append("车次数据不完整：%s" % code)
		return {}

	# 全程停站（运行顺序；arc 由停站所属线路换算，网外站 arc = -1）
	var stops: Array = []
	var offset := 0.0
	var prev_abs := -1.0
	for sr in stops_raw:
		var sid: String = sr["sid"]
		var sl = sr.get("line")
		var lid: String = str(sl) if sl != null and str(sl) != "" else ""
		var arc := -1.0
		if lid != "" and lines.has(lid) and lines[lid]["stations"].has(sid):
			arc = float(lines[lid]["station_arc"][sid])
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
			"sid": sid, "line": lid, "arr_s": arr_s, "dep_s": dep_s, "arc": arc,
			"name": station_name(lid, sid) if lid != "" else sid
		})

	# 腿解析：每腿内的停站弧长、区段（梯形速度包络参数）
	var legs: Array = []
	for lg in legs_raw:
		var lid: String = str(lg["line"])
		var i0: int = int(lg["i0"])
		var i1: int = int(lg["i1"])
		var transfer_path: Array = lg.get("transfer_path", [])
		if not lines.has(lid) or i1 <= i0 or i1 >= stops.size():
			data_warnings.append("%s 腿数据无效" % code)
			return {}
		var line: Dictionary = lines[lid]
		var leg_stops: Array = []
		for i in range(i0, i1 + 1):
			var st: Dictionary = stops[i].duplicate()
			st["arc"] = float(line["station_arc"][st["sid"]])
			leg_stops.append(st)
		var segs: Array = []
		for k in range(leg_stops.size() - 1):
			var a0: float = leg_stops[k]["arc"]
			var a1: float = leg_stops[k + 1]["arc"]
			var dur: float = leg_stops[k + 1]["arr_s"] - leg_stops[k]["dep_s"]
			segs.append({
				"arc0": a0, "arc1": a1, "len_m": absf(a1 - a0), "dur_s": dur,
				"accel": clampf(6000.0 / maxf(absf(a1 - a0), 1.0), 0.04, 0.25)
			})
		legs.append({
			"line": lid, "i0": i0, "i1": i1, "stops": leg_stops, "segs": segs,
			"t0": leg_stops[0]["dep_s"], "t1": leg_stops[leg_stops.size() - 1]["arr_s"],
			"arc0": leg_stops[0]["arc"], "arc1": leg_stops[leg_stops.size() - 1]["arc"],
			"transfer_path": transfer_path
		})

	var start_s: float = legs[0]["t0"]      # 进网/始发时刻
	var end_s: float = legs[legs.size() - 1]["t1"]
	if end_s <= start_s:
		data_warnings.append("%s 时刻非单调" % code)
		return {}
	for leg in legs:
		for st in leg["stops"]:
			st["arr_rel"] = st["arr_s"] - start_s
			st["dep_rel"] = st["dep_s"] - start_s
		leg["t0_rel"] = leg["t0"] - start_s
		leg["t1_rel"] = leg["t1"] - start_s

	# 腿间 transfer：沿铁路网真实路径移动（转换器预计算的站名路径）
	var transfers: Array = []
	for k in range(legs.size() - 1):
		var A: Dictionary = legs[k]
		var B: Dictionary = legs[k + 1]
		var t0r: float = A["t1_rel"]
		var t1r: float = B["t0_rel"]
		var pts := PackedVector2Array()
		var path: Array = A.get("transfer_path", [])
		for nm in path:
			var posv = _name_pos.get(str(nm))
			if posv != null:
				pts.append(posv)
		if pts.size() < 2:
			var pa: Vector2 = arc_point(A["line"], A["arc1"])["pos"]
			var pb: Vector2 = arc_point(B["line"], B["arc0"])["pos"]
			pts = PackedVector2Array([pa, pb])
		var total := 0.0
		for i in range(pts.size() - 1):
			total += pts[i].distance_to(pts[i + 1])
		transfers.append({"t0_rel": t0r, "t1_rel": t1r, "pts": pts,
				"total_m": total, "line": B["line"]})

	# 主线方向（显示兼容用）
	var primary: Dictionary = lines[line_id]
	var pl_legs: Array = []
	for leg in legs:
		if leg["line"] == line_id:
			pl_legs.append(leg)
	var dir_label := "down"
	for leg in pl_legs:
		if leg == pl_legs[0]:
			dir_label = "down" if leg["arc1"] > leg["arc0"] else "up"
			break

	return {
		"code": code,
		"line": line_id,
		"dir": dir_label,
		"type": tr.get("type", "CR400AF"),
		"from": tr.get("from", stops[0]["name"]),
		"to": tr.get("to", stops[stops.size() - 1]["name"]),
		"off_map": bool(tr.get("off_map", false)),
		"express": bool(tr.get("express", false)),
		"generated": bool(tr.get("generated", false)),
		"starts_on_net": int(legs[0]["i0"]) == 0,
		"ends_on_net": int(legs[legs.size() - 1]["i1"]) == stops.size() - 1,
		"stops": stops,
		"legs": legs,
		"transfers": transfers,
		"start_s": start_s,
		"end_s": end_s,
		"run_dur": end_s - start_s
	}


var _name_pos: Dictionary = {}  # 站名 -> 世界坐标（首个出现的线路）


func _build_name_pos() -> void:
	for line_id in line_order:
		var line: Dictionary = lines[line_id]
		for sid in line["order"]:
			var st: Dictionary = line["stations"][sid]
			if not _name_pos.has(st["name"]):
				_name_pos[st["name"]] = st["pos"]


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


func _build_background() -> void:
	var wcoast: Array = []
	for arr in background.get("coastlines", []):
		wcoast.append(_to_world_list(arr))
	background["wcoastlines"] = wcoast
	for river in background.get("rivers", []):
		river["wpts"] = _to_world_list(river.get("pts", []))
	for lake in background.get("lakes", []):
		lake["wpos"] = GeoScript.lonlat_to_world(float(lake["lon"]), float(lake["lat"]))
		lake["wrx"] = float(lake["rx"]) * GeoScript.M_PER_DEG_LON
		lake["wry"] = float(lake["ry"]) * GeoScript.M_PER_DEG_LAT
	for pl in background.get("province_labels", []):
		pl["wpos"] = GeoScript.lonlat_to_world(float(pl["lon"]), float(pl["lat"]))
	for c in background.get("cities", []):
		c["wpos"] = GeoScript.lonlat_to_world(float(c["lon"]), float(c["lat"]))
	# 省级行政边界（DataV GeoAtlas，抽稀后）
	var province_polys: Array = []
	if FileAccess.file_exists("res://data/map/provinces.json"):
		var pf := FileAccess.open("res://data/map/provinces.json", FileAccess.READ)
		var parsed = JSON.parse_string(pf.get_as_text())
		if typeof(parsed) == TYPE_ARRAY:
			for prov in parsed:
				var wpolys: Array = []
				for poly in prov.get("polys", []):
					var wpts := PackedVector2Array()
					for pt in poly:
						wpts.append(GeoScript.lonlat_to_world(float(pt[0]), float(pt[1])))
					wpolys.append(wpts)
				province_polys.append({"name": prov.get("name", ""), "polys": wpolys})
	background["provinces"] = province_polys


func _to_world_list(arr: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in arr:
		out.append(GeoScript.lonlat_to_world(float(p[0]), float(p[1])))
	return out


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


# 拾取距离 pos 最近的线路（折线段距离 < max_dist）
func nearest_line(pos: Vector2, max_dist: float) -> String:
	var best := ""
	var best_d := max_dist
	for line_id in line_order:
		var pts: Array = lines[line_id]["geometry_pts"]
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]["pos"]
			var b: Vector2 = pts[i + 1]["pos"]
			var ab := b - a
			var l2 := ab.length_squared()
			var t := clampf((pos - a).dot(ab) / l2, 0.0, 1.0) if l2 > 0.0 else 0.0
			var d: float = pos.distance_to(a + ab * t)
			if d < best_d:
				best_d = d
				best = line_id
	return best


func station_name(line_id: String, sid: String) -> String:
	var line: Dictionary = line(line_id)
	var st: Dictionary = line["stations"].get(sid, {})
	return str(st.get("name", sid))


func line_class(line_id: String) -> String:
	return str(line(line_id).get("line_class", "hsr250"))


func total_station_count() -> int:
	var n := 0
	for line_id in line_order:
		n += lines[line_id]["order"].size()
	return n

# 数据总线：加载线路/底图/车型/时刻表/成就，构建仿真所需的派生结构。
extends Node

const GeoScript := preload("res://src/core/geo.gd")

var line_data: Dictionary = {}
var background: Dictionary = {}
var train_types: Dictionary = {}          # id -> dict
var type_list: Array = []                 # 保持图鉴顺序
var achievements: Array = []              # 成就定义
var express_codes: Array = []             # 大站直达车次（成就用）

var stations: Dictionary = {}             # id -> {id,name,lon,lat,km,major,pos}
var station_order: Array = []             # 线路顺序的 station id
var geometry_pts: Array = []              # [{pos: Vector2, station: String}]
var cum: PackedFloat64Array               # 每个几何点的累计弧长（米）
var total_len_m: float = 0.0
var station_arc: Dictionary = {}          # sid -> 弧长（米）
var arc_marks: Array = []                 # [{sid, arc, km}] 按 arc 升序，用于里程换算

var map_center: Vector2 = Vector2.ZERO
var map_size: Vector2 = Vector2.ONE
var fit_zoom: float = 0.001

var trains: Array = []                    # 运行时列车（含解析后的相对时刻）
var train_by_code: Dictionary = {}

var data_warnings: Array = []


func _ready() -> void:
	line_data = _load_json("res://data/lines/jinghu_hsr.json")
	background = _load_json("res://data/map/background.json")
	var types_doc := _load_json("res://data/trains/train_types.json")
	var ach_doc := _load_json("res://data/achievements.json")

	for t in types_doc.get("types", []):
		train_types[t["id"]] = t
		type_list.append(t)
	achievements = ach_doc.get("achievements", [])

	_build_geometry()
	_build_background()
	_load_trains()

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


func _build_geometry() -> void:
	for s in line_data.get("stations", []):
		stations[s["id"]] = {
			"id": s["id"], "name": s["name"],
			"lon": float(s["lon"]), "lat": float(s["lat"]),
			"km": float(s["km"]), "major": bool(s.get("major", false)),
			"pos": GeoScript.lonlat_to_world(float(s["lon"]), float(s["lat"]))
		}
		station_order.append(s["id"])

	var min_p := Vector2.INF
	var max_p := -Vector2.INF
	for g in line_data.get("geometry", []):
		var pos: Vector2 = GeoScript.lonlat_to_world(float(g[0]), float(g[1]))
		geometry_pts.append({"pos": pos, "station": g[2] if g.size() > 2 and g[2] != null else ""})
		min_p = min_p.min(pos)
		max_p = max_p.max(pos)

	cum = PackedFloat64Array()
	cum.resize(geometry_pts.size())
	cum[0] = 0.0
	for i in range(1, geometry_pts.size()):
		cum[i] = cum[i - 1] + geometry_pts[i - 1]["pos"].distance_to(geometry_pts[i]["pos"])
	total_len_m = cum[cum.size() - 1]

	for p in geometry_pts:
		if p["station"] != "":
			station_arc[p["station"]] = cum[geometry_pts.find(p)]

	arc_marks = []
	for sid in station_order:
		arc_marks.append({"sid": sid, "arc": station_arc[sid], "km": stations[sid]["km"]})
	arc_marks.sort_custom(func(a, b): return a["arc"] < b["arc"])

	# 排查车站弧长顺序是否与站序一致（几何点序错误时告警）
	for i in range(station_order.size()):
		var sid: String = station_order[i]
		if absf(station_arc[sid] - arc_marks[i]["arc"]) > 1.0:
			data_warnings.append("几何点顺序与站序不一致（检查 geometry）：%s" % sid)
			break

	map_center = (min_p + max_p) * 0.5
	map_size = max_p - min_p
	# 视口 1600x900 下整线可见
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


func _to_world_list(arr: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in arr:
		out.append(GeoScript.lonlat_to_world(float(p[0]), float(p[1])))
	return out


func _load_trains() -> void:
	var real_doc := _load_json("res://data/timetables/real.json")
	var gen_doc := _load_json("res://data/timetables/generated.json")
	var raw: Array = []
	raw.append_array(real_doc.get("trains", []))
	raw.append_array(gen_doc.get("trains", []))

	for tr in raw:
		var train := _parse_train(tr)
		if train.is_empty():
			continue
		trains.append(train)
		train_by_code[train["code"]] = train
		if train.get("express", false):
			express_codes.append(train["code"])

	trains.sort_custom(func(a, b): return a["start_s"] < b["start_s"])
	print("DB: 已加载 %d 趟列车（几何全长 %.1f km）" % [trains.size(), total_len_m / 1000.0])


func _parse_train(tr: Dictionary) -> Dictionary:
	var code: String = tr.get("code", "")
	if code == "" or not tr.has("stops") or tr["stops"].size() < 2:
		data_warnings.append("车次数据不完整：%s" % code)
		return {}
	var stops_raw: Array = tr["stops"]
	var stops: Array = []
	var offset := 0.0
	var prev_abs := -1.0
	for i in range(stops_raw.size()):
		var sr: Dictionary = stops_raw[i]
		var sid: String = sr["sid"]
		if not stations.has(sid):
			data_warnings.append("%s 引用未知车站 %s" % [code, sid])
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
			arr_s = dep_s  # 始发站
		if dep_s < 0.0:
			dep_s = arr_s  # 终到站
		stops.append({
			"sid": sid, "arr_s": arr_s, "dep_s": dep_s,
			"arc": float(station_arc[sid])
		})

	var start_s: float = stops[0]["dep_s"]
	var end_s: float = stops[stops.size() - 1]["arr_s"]
	if end_s <= start_s:
		data_warnings.append("%s 时刻非单调" % code)
		return {}

	# 相对时刻 + 区段几何信息
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

	# 运行时段内的通过站统计（详情卡显示）
	var pass_counts: Array = []
	for i in range(stops.size() - 1):
		var i0 := station_order.find(stops[i]["sid"])
		var i1 := station_order.find(stops[i + 1]["sid"])
		pass_counts.append(absi(i1 - i0) - 1)

	return {
		"code": code,
		"type": tr.get("type", "CR400AF"),
		"dir": "down" if stops[0]["sid"] == station_order[0] else "up",
		"from": tr.get("from", stations[stops[0]["sid"]]["name"]),
		"to": tr.get("to", stations[stops[stops.size() - 1]["sid"]]["name"]),
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


# ---------- 几何查询 ----------

func arc_point(arc: float) -> Dictionary:
	var a := clampf(arc, 0.0, total_len_m)
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
	var pa: Vector2 = geometry_pts[lo]["pos"]
	var pb: Vector2 = geometry_pts[hi]["pos"]
	var dir := (pb - pa).normalized() if seg_len > 1.0 else Vector2.RIGHT
	return {"pos": pa.lerp(pb, f), "dir": dir}


func km_at_arc(arc: float) -> int:
	if arc_marks.is_empty():
		return 0
	if arc <= arc_marks[0]["arc"]:
		return int(arc_marks[0]["km"])
	for i in range(1, arc_marks.size()):
		if arc <= arc_marks[i]["arc"]:
			var m0: Dictionary = arc_marks[i - 1]
			var m1: Dictionary = arc_marks[i]
			var span: float = m1["arc"] - m0["arc"]
			var f: float = 0.0 if span <= 0.0 else (arc - m0["arc"]) / span
			return int(round(lerpf(m0["km"], m1["km"], f)))
	return int(arc_marks[arc_marks.size() - 1]["km"])


func nearest_station(pos: Vector2, max_dist_m: float = 1.0e9) -> String:
	var best := ""
	var best_d := max_dist_m
	for sid in station_order:
		var d: float = pos.distance_to(stations[sid]["pos"])
		if d < best_d:
			best_d = d
			best = sid
	return best


func station_by_id(sid: String) -> Dictionary:
	return stations.get(sid, {})


const GameTimeScript := preload("res://src/autoload/game_time.gd")

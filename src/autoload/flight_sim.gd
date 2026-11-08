# 航班仿真：加载 data/air/aviation.json（机场/航司/航线，OurAirports+OpenFlights
# 开放数据管线生成），按航线日频种子随机生成全天航班；大圆路径插值 +
# 爬升/巡航/下降三段剖面。时间与 GameTime 一致按 0~86400 循环，
# 红眼航班跨零点用取模处理（每日同一时刻起飞）。
extends Node

const GeoScript := preload("res://src/core/geo.gd")

const CLIMB_S := 840.0      # 爬升段 14 min
const DESC_S := 1320.0      # 下降段 22 min
const TAXI_S := 900.0       # 滑行/地面冗余（计入总时长）
const CRUISE_KMH := 870.0   # 巡航地速

var ready_ok := false
var airports: Dictionary = {}   # iata -> {iata,name,city,major,lon,lat,pos,routes_n,dep_arr}
var airport_list: Array = []
var airlines: Dictionary = {}   # code -> {name,color}
var routes: Array = []          # [{airline,from,to,daily,path,lens,total_len,dist_km,path8,path16}]
var flights: Array = []         # [{id,ri,al,al_name,al_color,from,to,dep,arr,dur}]
var _active_cache: Array = []   # 当前 60s 时间桶内的在途航班 idx
var _active_bin := -1

# 热路径平行数组（每帧 ~900 次解算，字典取值改为数组下标）
var _f_dep := PackedFloat64Array()
var _f_dur := PackedFloat64Array()
var _f_ri := PackedInt32Array()
var _f_pos0 := PackedVector2Array()   # 起飞机场世界坐标
var _f_pos1 := PackedVector2Array()   # 到达机场世界坐标
var _r_path: Array = []               # route idx -> PackedVector2Array
var _r_lens: Array = []               # route idx -> PackedFloat32Array
var _r_total := PackedFloat64Array()
var _r_dist := PackedFloat64Array()


func _ready() -> void:
	_load_data()
	if ready_ok:
		_build_schedule()
	print("[air] 航空就绪：机场 %d · 航线 %d · 日航班 %d" %
			[airport_list.size(), routes.size(), flights.size()])


func _load_data() -> void:
	if not FileAccess.file_exists("res://data/air/aviation.json"):
		push_warning("[air] data/air/aviation.json 缺失，航空系统未启用")
		return
	var f := FileAccess.open("res://data/air/aviation.json", FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for a in parsed.get("airports", []):
		var iata: String = str(a.get("iata", ""))
		if iata == "" or airports.has(iata):
			continue
		var lon: float = float(a.get("lon", 0.0))
		var lat: float = float(a.get("lat", 0.0))
		var rec := {
			"iata": iata, "name": str(a.get("name", iata)), "city": str(a.get("city", "")),
			"major": int(a.get("major", 0)), "lon": lon, "lat": lat,
			"pos": GeoScript.lonlat_to_world(lon, lat), "routes_n": 0, "dep_arr": 0,
		}
		airports[iata] = rec
		airport_list.append(rec)
	for al in parsed.get("airlines", []):
		var code: String = str(al.get("code", ""))
		if code == "" or airlines.has(code):
			continue
		airlines[code] = {"name": str(al.get("name", code)), "color": str(al.get("color", "#3f7fe0"))}
	for r in parsed.get("routes", []):
		var fi: String = str(r.get("from", ""))
		var ti: String = str(r.get("to", ""))
		if not airports.has(fi) or not airports.has(ti) or fi == ti:
			continue
		var fa: Dictionary = airports[fi]
		var ta: Dictionary = airports[ti]
		var daily: int = int(r.get("daily", 2))
		var path := _great_circle(fa["lon"], fa["lat"], ta["lon"], ta["lat"], 24)
		var lens := PackedFloat32Array()
		lens.append(0.0)
		var total := 0.0
		for i in range(1, path.size()):
			total += path[i - 1].distance_to(path[i])
			lens.append(total)
		var dist_km: float = GeoScript.lonlat_dist_m(fa["lon"], fa["lat"], ta["lon"], ta["lat"]) / 1000.0
		routes.append({
			"airline": str(r.get("airline", "")), "from": fi, "to": ti, "daily": daily,
			"path": path, "lens": lens, "total_len": total, "dist_km": dist_km,
			"path8": _resample(path, 8), "path16": _resample(path, 16),
		})
		fa["routes_n"] = int(fa["routes_n"]) + 1
		ta["routes_n"] = int(ta["routes_n"]) + 1
		fa["dep_arr"] = int(fa["dep_arr"]) + daily
		ta["dep_arr"] = int(ta["dep_arr"]) + daily
	ready_ok = not routes.is_empty()


# 球面大圆插值：经纬度 -> 单位向量 slerp -> 回投影（弧线自然向极点鼓起）
func _great_circle(lon0: float, lat0: float, lon1: float, lat1: float, steps: int) -> PackedVector2Array:
	var phi0 := deg_to_rad(lat0)
	var lam0 := deg_to_rad(lon0)
	var phi1 := deg_to_rad(lat1)
	var lam1 := deg_to_rad(lon1)
	var x0 := cos(phi0) * cos(lam0)
	var y0 := cos(phi0) * sin(lam0)
	var z0 := sin(phi0)
	var x1 := cos(phi1) * cos(lam1)
	var y1 := cos(phi1) * sin(lam1)
	var z1 := sin(phi1)
	var omega := acos(clampf(x0 * x1 + y0 * y1 + z0 * z1, -1.0, 1.0))
	var so := maxf(sin(omega), 1.0e-9)
	var pts := PackedVector2Array()
	for i in range(steps + 1):
		var f := float(i) / float(steps)
		var a := sin((1.0 - f) * omega) / so
		var b := sin(f * omega) / so
		var lat := rad_to_deg(asin(clampf(a * z0 + b * z1, -1.0, 1.0)))
		var lon := rad_to_deg(atan2(a * y0 + b * y1, a * x0 + b * x1))
		pts.append(GeoScript.lonlat_to_world(lon, lat))
	return pts


func _resample(path: PackedVector2Array, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var last := path.size() - 1
	for i in range(n):
		out.append(path[roundi(float(i) * float(last) / float(n - 1))])
	return out


# 按航线日频生成航班：出发时刻在 06:00~22:30 均匀铺开带抖动，
# 航班号 = 两字码 + 种子随机 4 位（同航司重号自动补后缀）
func _build_schedule() -> void:
	flights = []
	for ri in range(routes.size()):
		var r: Dictionary = routes[ri]
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(str(r["airline"]) + str(r["from"]) + str(r["to"]))
		var n: int = r["daily"]
		var dur := maxf(r["dist_km"] / CRUISE_KMH * 3600.0 + TAXI_S, 2700.0)
		var span0 := 6.0 * 3600.0
		var span1 := 22.5 * 3600.0
		for i in range(n):
			var dep := span0 + (span1 - span0) * (float(i) + rng.randf_range(0.15, 0.85)) / float(n)
			var num := 1000 + rng.randi() % 7800
			flights.append({
				"ri": ri, "dep": dep, "arr": fposmod(dep + dur, 86400.0), "dur": dur,
				"num": "%s%d" % [str(r["airline"]), num],
			})
	var used := {}
	for i in range(flights.size()):
		var fl: Dictionary = flights[i]
		var r2: Dictionary = routes[fl["ri"]]
		var al: String = str(r2["airline"])
		fl["al"] = al
		var alr: Dictionary = airlines.get(al, {"name": al, "color": "#3f7fe0"})
		fl["al_name"] = str(alr["name"])
		fl["al_color"] = str(alr["color"])
		fl["from"] = str(r2["from"])
		fl["to"] = str(r2["to"])
		var id: String = str(fl["num"])
		var k := 0
		while used.has(id):
			k += 1
			id = "%s-%d" % [fl["num"], k]
		used[id] = true
		fl["id"] = id
	# 热路径平行数组
	_f_dep = PackedFloat64Array()
	_f_dur = PackedFloat64Array()
	_f_ri = PackedInt32Array()
	_f_pos0 = PackedVector2Array()
	_f_pos1 = PackedVector2Array()
	_f_dep.resize(flights.size())
	_f_dur.resize(flights.size())
	_f_ri.resize(flights.size())
	_f_pos0.resize(flights.size())
	_f_pos1.resize(flights.size())
	for i in range(flights.size()):
		var fl2: Dictionary = flights[i]
		var r3: Dictionary = routes[fl2["ri"]]
		_f_dep[i] = float(fl2["dep"])
		_f_dur[i] = float(fl2["dur"])
		_f_ri[i] = int(fl2["ri"])
		_f_pos0[i] = airports[r3["from"]]["pos"]
		_f_pos1[i] = airports[r3["to"]]["pos"]
	_r_path = []
	_r_lens = []
	_r_total = PackedFloat64Array()
	_r_dist = PackedFloat64Array()
	for r4 in routes:
		_r_path.append(r4["path"])
		_r_lens.append(r4["lens"])
		_r_total.append(float(r4["total_len"]))
		_r_dist.append(float(r4["dist_km"]))


# 当前在途航班 idx 列表（60 游戏秒粒度缓存）
func active_flights(t: float) -> Array:
	var bin := int(t / 60.0)
	if bin != _active_bin:
		_active_bin = bin
		_active_cache = []
		for i in range(flights.size()):
			var fl: Dictionary = flights[i]
			if fposmod(t - float(fl["dep"]), 86400.0) < float(fl["dur"]):
				_active_cache.append(i)
	return _active_cache


# 沿路径弧长参数取点
func point_at(r: Dictionary, prog: float) -> Vector2:
	var path: PackedVector2Array = r["path"]
	var lens: PackedFloat32Array = r["lens"]
	var target: float = clampf(prog, 0.0, 1.0) * float(r["total_len"])
	var lo := 0
	var hi := lens.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if lens[mid] < target:
			lo = mid + 1
		else:
			hi = mid
	var i := maxi(lo, 1)
	var seg: float = lens[i] - lens[i - 1]
	var f := 0.0 if seg <= 0.0 else (target - lens[i - 1]) / seg
	return path[i - 1].lerp(path[i], f)


# 航班状态：phase = pre(待起飞) / climb / cruise / descend / done(已到达)
func state_for(idx: int, t: float) -> Dictionary:
	var dep := _f_dep[idx]
	var dur := _f_dur[idx]
	var el := fposmod(t - dep, 86400.0)
	if el >= dur:
		var since := el - dur
		var until := 86400.0 - el
		if until < since:
			return {"phase": "pre", "pos": _f_pos0[idx], "heading": 0.0,
					"alt": 0.0, "speed": 0.0, "prog": 0.0, "remain": until}
		return {"phase": "done", "pos": _f_pos1[idx], "heading": 0.0,
				"alt": 0.0, "speed": 0.0, "prog": 1.0, "remain": 0.0}
	var ri := _f_ri[idx]
	var prog := el / dur
	var cruise_alt := 9000.0 + minf(2000.0, _r_dist[ri] * 1.5)
	var phase: String
	var alt: float
	var speed: float
	if el < CLIMB_S:
		phase = "climb"
		var f := el / CLIMB_S
		alt = cruise_alt * f * f
		speed = 320.0 + 530.0 * f
	elif el > dur - DESC_S:
		phase = "descend"
		var f2 := (dur - el) / DESC_S
		alt = cruise_alt * f2 * f2
		speed = 390.0 + 470.0 * f2
	else:
		phase = "cruise"
		alt = cruise_alt
		speed = CRUISE_KMH
	# 单次二分定位：位置由相邻路径点插值，切线即航向
	var path: PackedVector2Array = _r_path[ri]
	var lens: PackedFloat32Array = _r_lens[ri]
	var target := prog * _r_total[ri]
	var lo := 0
	var hi := lens.size() - 1
	while lo < hi - 1:
		var mid := (lo + hi) >> 1
		if lens[mid] <= target:
			lo = mid
		else:
			hi = mid
	var seg_len := lens[hi] - lens[lo]
	var sf := 0.0 if seg_len <= 0.0 else (target - lens[lo]) / seg_len
	var pa := path[lo]
	var pb := path[hi]
	var dirv := pb - pa
	var heading := dirv.angle() if dirv.length_squared() > 1.0 else 0.0
	return {"phase": phase, "pos": pa.lerp(pb, sf), "heading": heading,
			"alt": alt, "speed": speed, "prog": prog, "remain": dur - el}


# 某机场出发航班 idx（按距当前时刻的起飞间隔升序，出发大屏用）
func airport_departures(iata: String, t: float) -> Array:
	var out := []
	for i in range(flights.size()):
		if str(flights[i]["from"]) == iata:
			out.append(i)
	out.sort_custom(func(a, b):
		return fposmod(flights[a]["dep"] - t, 86400.0) < fposmod(flights[b]["dep"] - t, 86400.0))
	return out


# 通达目的地 top（按日班次）
func airport_top_dest(iata: String, limit: int = 8) -> Array:
	var daily := {}
	for r in routes:
		var d := ""
		if str(r["from"]) == iata:
			d = str(r["to"])
		elif str(r["to"]) == iata:
			d = str(r["from"])
		else:
			continue
		daily[d] = int(daily.get(d, 0)) + int(r["daily"])
	var arr := []
	for k in daily:
		arr.append([k, daily[k]])
	arr.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	return arr.slice(0, limit)

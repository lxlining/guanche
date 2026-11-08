# 元进度：观测记录、图鉴、成就、机位、存档。
extends Node

signal type_discovered(type_id: String)
signal achievement_unlocked(ach: Dictionary)
signal spots_changed
signal spot_mode_changed(enabled: bool)
signal class_visibility_changed
signal focus_line_changed
signal focus_mode_changed
signal checkin_made(sname: String, total: int)
signal search_history_changed
signal aviation_changed

const GeoScript := preload("res://src/core/geo.gd")
const SAVE_PATH := "user://savegame.json"
const MAX_SPOTS := 5
const SPOT_RADIUS_M := 6000.0
const OBSERVE_COOLDOWN := 1800.0  # 同车次 30 游戏分钟内不重复计数

var spot_mode: bool = false
var spots: Array = []             # {id, name, lon, lat, world, r_m}
var _spot_seq := 0

var checkins: Dictionary = {}     # 站名 -> {t: 首次打卡游戏时刻, n: 打卡次数}
var search_history: Array = []    # 最近搜索词（新在前，去重，≤8）
var discovered: Dictionary = {}   # type_id -> {t, code, station}
var spotted: Dictionary = {}      # code -> {count, first_t, last_t}
var unlocked: Array = []          # 成就 id
var window_codes: Dictionary = {} # 小时 -> {code: true}
var followed_codes: Array = []
var max_follow_km: float = 0.0
var full_journey_done: bool = false
var cross_meet_done: bool = false
var screen_done: bool = false
var visited: Dictionary = {}      # sid -> true

var _last_observe: Dictionary = {}  # code -> 上次观测的游戏时刻
var is_fresh: bool = true           # 从未存过档（用于首次引导）
var class_visible: Dictionary = {"hsr350": true, "hsr250": true, "intercity": true, "conventional": true, "freight": true}
var focus_line: String = ""
var focus_train: String = ""          # 车次专注：仅显示该车与其走线
var focus_train_lines: Dictionary = {}  # line_id -> true（该车全部走线）
var aviation_on: bool = false         # 航空模式（航线弧/机场/航班）
var flights_seen: Dictionary = {}     # 航班号 -> 观测次数


func set_aviation(on: bool) -> void:
	if aviation_on == on:
		return
	aviation_on = on
	aviation_changed.emit()
	save()


func observe_flight(fid: String) -> void:
	flights_seen[fid] = int(flights_seen.get(fid, 0)) + 1


func set_focus_line(line_id: String) -> void:
	focus_line = line_id
	focus_train = ""
	focus_train_lines = {}
	focus_line_changed.emit()
	focus_mode_changed.emit()


func set_focus_train(code: String) -> void:
	focus_train = code
	focus_train_lines = {}
	focus_line = ""
	if code != "" and DB.train_by_code.has(code):
		for leg in DB.train_by_code[code]["legs"]:
			focus_train_lines[str(leg["line"])] = true
	focus_line_changed.emit()
	focus_mode_changed.emit()


func clear_focus() -> void:
	var had := focus_line != "" or focus_train != ""
	focus_line = ""
	focus_train = ""
	focus_train_lines = {}
	if had:
		focus_line_changed.emit()
		focus_mode_changed.emit()


func focus_active() -> bool:
	return focus_line != "" or focus_train != ""


# line_id 是否应被隐藏（专注模式下属走线集合的线路不隐藏）
func is_focus_line(line_id: String) -> bool:
	if focus_train != "":
		return not focus_train_lines.has(line_id)
	return focus_line != "" and focus_line != line_id


func set_class_visible(cls: String, on: bool) -> void:
	class_visible[cls] = on
	class_visibility_changed.emit()
	save()


func is_class_visible(cls: String) -> bool:
	return bool(class_visible.get(cls, true))


func _ready() -> void:
	_load_save()


# ---------- 观测 ----------

# 记录一次观测。返回是否为有效新记录（冷却去重后）。
func observe(code: String, type_id: String, t: float, station_name: String) -> bool:
	var last = _last_observe.get(code, -1.0e9)
	if GameTime.circular_diff(t, last) < OBSERVE_COOLDOWN:
		return false
	_last_observe[code] = t

	var sp: Dictionary = spotted.get(code, {})
	if sp.is_empty():
		spotted[code] = {"count": 1, "first_t": t, "last_t": t}
	else:
		sp["count"] = int(sp.get("count", 0)) + 1
		sp["last_t"] = t

	var h := int(t / 3600.0)
	if not window_codes.has(h):
		window_codes[h] = {}
	window_codes[h][code] = true

	if not discovered.has(type_id):
		discovered[type_id] = {"t": t, "code": code, "station": station_name}
		type_discovered.emit(type_id)

	check_achievements()
	return true


func visit_station(sid: String) -> void:
	if visited.has(sid):
		return
	visited[sid] = true
	check_achievements()

# ---------- 打卡 ----------

# 在车站打卡：首次记录时刻，重复打卡累加次数。返回是否为首次。
func checkin(sname: String) -> bool:
	if checkins.has(sname):
		checkins[sname]["n"] = int(checkins[sname].get("n", 1)) + 1
		return false
	checkins[sname] = {"t": GameTime.t, "n": 1}
	check_achievements()
	checkin_made.emit(sname, checkins.size())
	return true


func checkin_total() -> int:
	return checkins.size()


func push_search(q: String) -> void:
	q = q.strip_edges()
	if q == "":
		return
	search_history.erase(q)
	search_history.insert(0, q)
	if search_history.size() > 8:
		search_history.resize(8)
	search_history_changed.emit()
	save()


func report_screen_trains(n: int) -> void:
	if n >= 10 and not screen_done:
		screen_done = true
		check_achievements()


func report_cross_meet() -> void:
	if cross_meet_done:
		return
	cross_meet_done = true
	check_achievements()


func report_follow_session(code: String, dist_km: float, completed: bool,
		full_line: bool, started_at_departure: bool) -> void:
	if not followed_codes.has(code):
		followed_codes.append(code)
	max_follow_km = maxf(max_follow_km, dist_km)
	if completed and full_line and started_at_departure:
		full_journey_done = true
	check_achievements()


# ---------- 成就 ----------

func check_achievements() -> void:
	for def in DB.achievements:
		if def["id"] in unlocked:
			continue
		if _eval(def):
			_unlock(def)


func _eval(def: Dictionary) -> bool:
	match def.get("check", ""):
		"spots_min":
			return spotted.size() >= int(def.get("n", 1))
		"window_min":
			var from_h := int(def.get("from", 0))
			var to_h := mini(int(def.get("to", 24)), 24)
			var cnt := 0
			for h in range(from_h, to_h):
				if window_codes.has(h):
					cnt += window_codes[h].size()
			return cnt >= int(def.get("n", 1))
		"types_min":
			return discovered.size() >= int(def.get("n", 1))
		"types_all":
			return discovered.size() >= DB.type_list.size()
		"types_include":
			for tid in def.get("list", []):
				if not discovered.has(tid):
					return false
			return true
		"express_min":
			var cnt := 0
			for code in DB.express_codes:
				if spotted.has(code):
					cnt += 1
			return cnt >= int(def.get("n", 1))
		"full_journey":
			return full_journey_done
		"follow_km":
			return max_follow_km >= float(def.get("km", 1.0e9))
		"follow_count":
			return followed_codes.size() >= int(def.get("n", 1))
		"cross_meet":
			return cross_meet_done
		"stations_all":
			return visited.size() >= DB.total_station_count()
		"screen_trains":
			return screen_done
		"checkins_min":
			return checkins.size() >= int(def.get("n", 1))
	return false


func _unlock(def: Dictionary) -> void:
	unlocked.append(def["id"])
	achievement_unlocked.emit(def)
	save()


# 成就进度文本（用于成就界面），无进度概念时返回空串
func progress_text(def: Dictionary) -> String:
	match def.get("check", ""):
		"spots_min":
			return "%d/%d" % [spotted.size(), int(def.get("n", 1))]
		"window_min":
			var from_h := int(def.get("from", 0))
			var to_h := mini(int(def.get("to", 24)), 24)
			var cnt := 0
			for h in range(from_h, to_h):
				if window_codes.has(h):
					cnt += window_codes[h].size()
			return "%d/%d" % [cnt, int(def.get("n", 1))]
		"types_min":
			return "%d/%d" % [discovered.size(), int(def.get("n", 1))]
		"types_all":
			return "%d/%d" % [discovered.size(), DB.type_list.size()]
		"types_include":
			var have := 0
			var ids: Array = def.get("list", [])
			for tid in ids:
				if discovered.has(tid):
					have += 1
			return "%d/%d" % [have, ids.size()]
		"express_min":
			var cnt := 0
			for code in DB.express_codes:
				if spotted.has(code):
					cnt += 1
			return "%d/%d" % [cnt, int(def.get("n", 1))]
		"follow_km":
			return "%d/%d km" % [int(max_follow_km), int(def.get("km", 0))]
		"follow_count":
			return "%d/%d" % [followed_codes.size(), int(def.get("n", 1))]
		"stations_all":
			return "%d/%d" % [visited.size(), DB.total_station_count()]
		"checkins_min":
			return "%d/%d" % [checkins.size(), int(def.get("n", 1))]
	return ""


# ---------- 机位 ----------

func set_spot_mode(on: bool) -> void:
	spot_mode = on
	spot_mode_changed.emit(on)


func toggle_spot_mode() -> void:
	set_spot_mode(not spot_mode)


# 机位模式下的点击：附近已有机位则移动它；否则新增；满额则移动最近机位
func place_spot(world: Vector2) -> void:
	var target: Dictionary = {}
	var best_d := 8000.0
	for s in spots:
		var d: float = s["world"].distance_to(world)
		if d < best_d:
			best_d = d
			target = s
	if target.is_empty() and spots.size() >= MAX_SPOTS:
		var nd := 1.0e18
		for s in spots:
			var d: float = s["world"].distance_to(world)
			if d < nd:
				nd = d
				target = s
	var lonlat := GeoScript.world_to_lonlat(world)
	if target.is_empty():
		_spot_seq += 1
		spots.append({
			"id": _spot_seq, "name": "机位 %d" % _spot_seq,
			"lon": lonlat.x, "lat": lonlat.y,
			"world": world, "r_m": SPOT_RADIUS_M
		})
	else:
		target["lon"] = lonlat.x
		target["lat"] = lonlat.y
		target["world"] = world
	spots_changed.emit()


func remove_nearest_spot(world: Vector2, max_dist_m: float) -> bool:
	var best_idx := -1
	var nd := max_dist_m
	for i in range(spots.size()):
		var d: float = spots[i]["world"].distance_to(world)
		if d < nd:
			nd = d
			best_idx = i
	if best_idx < 0:
		return false
	spots.remove_at(best_idx)
	spots_changed.emit()
	return true


# ---------- 存档 ----------

func save() -> void:
	var spots_data: Array = []
	for s in spots:
		spots_data.append({"id": s["id"], "name": s["name"], "lon": s["lon"], "lat": s["lat"]})
	var d := {
		"v": 1,
		"game_t": GameTime.t, "speed": GameTime.speed, "paused": GameTime.paused,
		"discovered": discovered, "spotted": spotted, "unlocked": unlocked,
		"window_codes": window_codes, "followed": followed_codes,
		"max_follow_km": max_follow_km, "full": full_journey_done,
		"cross": cross_meet_done, "screen": screen_done,
		"visited": visited.keys(), "spots": spots_data,
		"class_visible": class_visible, "checkins": checkins,
		"search_history": search_history,
		"aviation_on": aviation_on, "flights_seen": flights_seen
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d, "  "))
		f.close()


func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	is_fresh = false
	GameTime.t = float(parsed.get("game_t", GameTime.t))
	checkins = parsed.get("checkins", {})
	search_history = parsed.get("search_history", [])
	aviation_on = bool(parsed.get("aviation_on", false))
	flights_seen = parsed.get("flights_seen", {})
	GameTime.speed = float(parsed.get("speed", GameTime.speed))
	GameTime.paused = bool(parsed.get("paused", false))
	discovered = parsed.get("discovered", {})
	spotted = parsed.get("spotted", {})
	unlocked = parsed.get("unlocked", [])
	window_codes = {}
	for key in parsed.get("window_codes", {}):
		window_codes[int(key)] = parsed["window_codes"][key]  # JSON 键为字符串，还原为整数小时
	followed_codes = parsed.get("followed", [])
	max_follow_km = float(parsed.get("max_follow_km", 0.0))
	full_journey_done = bool(parsed.get("full", false))
	cross_meet_done = bool(parsed.get("cross", false))
	screen_done = bool(parsed.get("screen", false))
	for cls in parsed.get("class_visible", {}).keys():
		class_visible[cls] = bool(parsed["class_visible"][cls])
	visited = {}
	for sid in parsed.get("visited", []):
		visited[sid] = true
	spots = []
	for s in parsed.get("spots", []):
		_spot_seq = maxi(_spot_seq, int(s.get("id", 0)))
		spots.append({
			"id": int(s.get("id", 0)), "name": s.get("name", "机位"),
			"lon": float(s["lon"]), "lat": float(s["lat"]),
			"world": GeoScript.lonlat_to_world(float(s["lon"]), float(s["lat"])),
			"r_m": SPOT_RADIUS_M
		})

# 仿真内核：时刻表 + 多线路腿结构 -> 任意游戏时刻的列车状态。
# 列车按真实路径跨线运行：腿（leg）= 同一线路上的连续停站区间，
# 腿间以 transfer（联络/跨线直线移动）衔接。状态为纯函数解算。
extends Node

const WAIT_WINDOW := 1800.0  # 网内始发列车发车前 30 分钟显示「待发」

var states: Dictionary = {}  # code -> 状态字典（当前时刻）

var _last_t := -1.0
var _rr := 0                 # 轮转游标：预算制逐帧刷新全量列车
const OFFVIEW_BUDGET := 400  # 每帧为轮转列车解算的最大数量
const VIEW_CAP := 500        # 每帧视口内逐帧解算的上限（超出并入轮转）
var _codes := PackedStringArray()   # 平行数组：免每帧 9686 次字典字符串哈希
var _pos_arr := PackedVector2Array()
var _dir_arr := PackedVector2Array()
var _cur_line := PackedStringArray()
var _type_arr := PackedStringArray()
var _freight_arr := PackedByteArray()
var _status_arr := PackedByteArray()   # 0=off 1=run 2=stop 3=wait
var _arrays_ready := false


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var t := GameTime.t
	if t == _last_t:
		return  # 暂停/时刻未变：状态冻结，跳过全量解算
	_last_t = t
	# 性能：视口内列车每帧解算（近景平滑）；其余列车轮转预算更新，
	# 全量 9686 车在 ~0.25s 内轮完，位置滞后对远景/统计不可感。
	var vp_rect := _view_rect()
	var n := DB.trains.size()
	if n == 0:
		return
	_ensure_arrays(n)
	# 自适应预算：近景（视口内列车已逐帧解算）压低离屏刷新至 1/3，
	# 全国视野保持全量轮转节奏
	var cam0 := get_viewport().get_camera_2d()
	var z0 := cam0.zoom.x if cam0 != null else 0.0
	var budget := OFFVIEW_BUDGET if z0 < 0.006 else OFFVIEW_BUDGET / 3
	# 视口内解算上限：全国视野下视口=全网（9686 辆全部逐帧解算是原 1fps 根因），
	# 超出上限的视口列车并入轮转预算（全国视野 ~1.2s 轮完一遍）
	var view_upd := 0
	var processed := 0
	var i := _rr
	var last_budget := -1
	while processed < n:
		var in_view := vp_rect.size.x > 0.0 and vp_rect.has_point(_pos_arr[i]) \
				and view_upd < VIEW_CAP
		if in_view:
			view_upd += 1
		if in_view or budget > 0:
			var st: Dictionary = state_for(DB.trains[i], t)
			var code_i := _codes[i]
			states[code_i] = st
			var status := str(st.get("status", "off"))
			_status_arr[i] = 1 if status == "run" else (2 if status == "stop" else (3 if status == "wait" else 0))
			if st.has("pos"):
				_pos_arr[i] = st["pos"]
				_dir_arr[i] = st["dirv"]
				_cur_line[i] = str(st.get("line", ""))
			# 游标只由「预算更新」推进——in_view 更新是位置驱动的每帧重复，
			# 若让其回卷游标会造成原地打转、其余列车永远轮不到
			if in_view:
				pass
			else:
				budget -= 1
				last_budget = i
		i = (i + 1) % n
		processed += 1
	if last_budget >= 0:
		_rr = (last_budget + 1) % n
	if OS.get_environment("SIM_DEBUG") != "":
		print("[sim] t=%.2f rr=%d states=%d" % [t, _rr, states.size()])
	PerfProbe.lap("sim", Time.get_ticks_usec() - t0)


func _view_rect() -> Rect2:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return Rect2()
	var vp := get_viewport().get_visible_rect().size
	return Rect2(cam.get_screen_center_position() - vp * 0.5 / cam.zoom.x,
			vp / cam.zoom.x).grow(50000.0)


# 纯解算：给定列车与时刻，返回状态。
# status: off(未上线/已收车) / wait(网内始发待发) / run(运行) / stop(停站) / done(终到)
func state_for(train: Dictionary, t: float) -> Dictionary:
	var rel := fposmod(t - train["start_s"], 86400.0)
	var dur: float = train["run_dur"]
	var legs: Array = train["legs"]

	if rel > dur:
		if bool(train.get("starts_on_net", true)) and rel >= 86400.0 - WAIT_WINDOW:
			var leg0: Dictionary = legs[0]
			var s0: Dictionary = leg0["stops"][0]
			return _state_at_stop(train, leg0["line"], s0, rel, 0, leg0["i0"])
		return {"code": train["code"], "status": "off"}

	for k in range(legs.size()):
		var leg: Dictionary = legs[k]
		if rel > leg["t1_rel"]:
			continue
		if rel < leg["t0_rel"]:
			# 处于本腿之前的 transfer（k > 0；k == 0 时 rel < t0_rel 不可能，
			# 因为 start_s 即 legs[0].t0）
			var tr: Dictionary = train["transfers"][k - 1]
			return _transfer_state(train, tr, rel, legs[k])
		return _state_in_leg(train, leg, rel)
	# rel 超过最后一腿（时间缝隙内已处理）——收车
	return {"code": train["code"], "status": "done"}


func _state_in_leg(train: Dictionary, leg: Dictionary, rel: float) -> Dictionary:
	var stops_l: Array = leg["stops"]
	var segs: Array = leg["segs"]
	var line_id: String = leg["line"]

	for i in range(stops_l.size()):
		if rel < stops_l[i]["dep_rel"]:
			if rel >= stops_l[i]["arr_rel"]:
				return _state_at_stop(train, line_id, stops_l[i], rel,
						leg["i0"] + i, leg["i0"] + i + 1)
			# 区间运行：segs[i-1] 连接 stops[i-1] -> stops[i]
			var seg: Dictionary = segs[i - 1]
			var tau: float = (rel - stops_l[i - 1]["dep_rel"]) / maxf(
					stops_l[i]["arr_rel"] - stops_l[i - 1]["dep_rel"], 1.0)
			var p: float = _trapezoid_progress(tau, seg["accel"])
			var arc: float = lerpf(seg["arc0"], seg["arc1"], p)
			var slope: float = _trapezoid_slope(tau, seg["accel"])
			var v_kmh: float = seg["len_m"] / maxf(seg["dur_s"], 1.0) * slope * 3.6
			var rpt := DB.arc_pos(line_id, arc)
			var dirv: Vector2 = _probe_dir(line_id, arc, leg)
			return _mk_state(train, line_id, "run", rpt, dirv,
					DB.km_at_arc(line_id, arc), rel, leg["i0"] + i, leg["i0"] + i + 1,
					minf(v_kmh, 350.0))
	# 已驶离本腿末端（时间缝隙由 transfer 分支处理，此处兜底收车）
	return {"code": train["code"], "status": "done"}


func _transfer_state(train: Dictionary, tr: Dictionary, rel: float,
		next_leg: Dictionary) -> Dictionary:
	# 沿铁路网真实路径（途经站折线）按弧长均匀插值。
	# 性能：联络线折线可达数千点，逐次线性扫是近景帧率杀手——
	# 累积弧长懒构建 + 二分查找定位。
	var span: float = maxf(tr["t1_rel"] - tr["t0_rel"], 1.0)
	var f := clampf((rel - tr["t0_rel"]) / span, 0.0, 1.0)
	var pts: PackedVector2Array = tr["pts"]
	var total: float = maxf(tr["total_m"], 1.0)
	var target: float = f * total
	var cum_v: Variant = tr.get("cum")
	var cum: PackedFloat64Array = cum_v if cum_v is PackedFloat64Array else PackedFloat64Array()
	if cum.is_empty():
		var acc0 := 0.0
		cum.append(0.0)
		for i in range(pts.size() - 1):
			acc0 += pts[i].distance_to(pts[i + 1])
			cum.append(acc0)
		tr["cum"] = cum
	# 二分：找 cum[lo] <= target <= cum[hi]
	var lo := 0
	var hi := cum.size() - 1
	while lo < hi - 1:
		var mid := (lo + hi) >> 1
		if cum[mid] <= target:
			lo = mid
		else:
			hi = mid
	var seg := cum[hi] - cum[lo]
	var t := 0.0 if seg <= 0.0 else (target - cum[lo]) / seg
	var pos: Vector2 = pts[lo].lerp(pts[hi], t)
	var dirv := (pts[hi] - pts[lo]).normalized() if (pts[hi] - pts[lo]).length_squared() > 1.0 else Vector2.RIGHT
	var v_kmh: float = total / 1000.0 / maxf(span / 3600.0, 0.01)
	var next_stop: Dictionary = train["stops"][next_leg["i0"]]
	return _mk_state(train, str(next_stop.get("line", "")), "run", pos, dirv,
			DB.km_at_arc(str(next_stop.get("line", "")), next_leg["arc0"]), rel,
			next_leg["i0"], next_leg["i0"] + 1, minf(v_kmh, 350.0))


func _state_at_stop(train: Dictionary, line_id: String, stop: Dictionary,
		rel: float, stop_idx: int, next_idx: int) -> Dictionary:
	var spt := DB.arc_pos(line_id, stop["arc"])
	var dirv: Vector2 = _probe_dir(line_id, stop["arc"], null)
	return _mk_state(train, line_id, "stop", spt, dirv,
			DB.km_at_arc(line_id, stop["arc"]), rel, stop_idx, next_idx, 0.0)


# 箭头朝向探测：沿行驶方向取前方 80m 采样（与 down=弧长递增同一套定义）
func _probe_dir(line_id: String, arc: float, leg) -> Vector2:
	var sign := 1.0
	if leg != null:
		sign = 1.0 if leg["arc1"] > leg["arc0"] else -1.0
	var p0 := DB.arc_pos(line_id, arc)
	var p1 := DB.arc_pos(line_id, arc + 80.0 * sign)
	var dv := p1 - p0
	if dv.length_squared() > 1.0:
		return dv.normalized()
	return dv


func _mk_state(train: Dictionary, line_id: String, status: String, pos: Vector2,
		dirv: Vector2, km: int, rel: float, stop_idx: int, next_idx: int,
		v_kmh: float = 0.0) -> Dictionary:
	var stops: Array = train["stops"]
	var st := {
		"code": train["code"], "type": train["type"], "dir": train["dir"],
		"line": line_id,
		"status": status, "pos": pos, "dirv": dirv,
		"speed_kmh": minf(v_kmh, 350.0), "km": km,
		"rel": rel, "stop_idx": stop_idx
	}
	if next_idx < stops.size():
		st["next_sid"] = stops[next_idx]["sid"]
		st["next_line"] = str(stops[next_idx].get("line", line_id))
		st["next_arr_s"] = stops[next_idx]["arr_s"]
		st["next_name"] = str(stops[next_idx].get("name", st["next_sid"]))
	else:
		st["next_sid"] = ""
		st["next_line"] = ""
		st["next_arr_s"] = -1.0
		st["next_name"] = ""
	return st


func _trapezoid_progress(tau: float, a: float) -> float:
	var v := 1.0 / (1.0 - a)
	if tau <= a:
		return v * tau * tau / (2.0 * a)
	if tau <= 1.0 - a:
		return v * (tau - a) + v * a * 0.5
	var u := 1.0 - tau
	return 1.0 - v * u * u / (2.0 * a)


func _trapezoid_slope(tau: float, a: float) -> float:
	var v := 1.0 / (1.0 - a)
	if tau <= a:
		return v * tau / a
	if tau <= 1.0 - a:
		return v
	return v * (1.0 - tau) / a

# ---------- 渲染层热路径：平行数组索引访问（免字典哈希） ----------

func count() -> int:
	_ensure_arrays(DB.trains.size())
	return DB.trains.size()

# 平行数组懒初始化（渲染层可能在 Simulation 首帧前访问）
func _ensure_arrays(n: int) -> void:
	if _arrays_ready and _codes.size() == n:
		return
	_codes = PackedStringArray()
	_pos_arr = PackedVector2Array()
	_dir_arr = PackedVector2Array()
	_cur_line = PackedStringArray()
	_type_arr = PackedStringArray()
	_freight_arr = PackedByteArray()
	_status_arr = PackedByteArray()
	_codes.resize(n)
	_pos_arr.resize(n)
	_dir_arr.resize(n)
	_cur_line.resize(n)
	_type_arr.resize(n)
	_freight_arr.resize(n)
	_status_arr.resize(n)
	for k in range(n):
		var tr0: Dictionary = DB.trains[k]
		_codes[k] = str(tr0["code"])
		_pos_arr[k] = Vector2.INF
		_type_arr[k] = str(tr0.get("type", ""))
		_freight_arr[k] = 1 if bool(tr0.get("freight", false)) else 0
	_arrays_ready = true




func code_at(i: int) -> String:
	_ensure_arrays(DB.trains.size())
	return _codes[i]


func pos_at(i: int) -> Vector2:
	_ensure_arrays(DB.trains.size())
	return _pos_arr[i]


func dir_at(i: int) -> Vector2:
	return _dir_arr[i]


func status_at(i: int) -> int:
	_ensure_arrays(DB.trains.size())
	return _status_arr[i]


func type_at(i: int) -> String:
	return _type_arr[i]


func freight_at(i: int) -> bool:
	return _freight_arr[i] == 1


func cur_line_at(i: int) -> String:
	return _cur_line[i]


func train_on_line_at(i: int, line_id: String) -> bool:
	for leg in DB.trains[i]["legs"]:
		if str(leg["line"]) == line_id:
			return true
	return false

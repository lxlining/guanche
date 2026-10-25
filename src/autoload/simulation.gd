# 仿真内核：时刻表 + 多线路腿结构 -> 任意游戏时刻的列车状态。
# 列车按真实路径跨线运行：腿（leg）= 同一线路上的连续停站区间，
# 腿间以 transfer（联络/跨线直线移动）衔接。状态为纯函数解算。
extends Node

const WAIT_WINDOW := 1800.0  # 网内始发列车发车前 30 分钟显示「待发」

var states: Dictionary = {}  # code -> 状态字典（当前时刻）


func _process(_delta: float) -> void:
	var t := GameTime.t
	for train in DB.trains:
		states[train["code"]] = state_for(train, t)


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
			var pt := DB.arc_point(line_id, arc)
			var dirv: Vector2 = _probe_dir(line_id, arc, leg)
			return _mk_state(train, line_id, "run", pt["pos"], dirv,
					DB.km_at_arc(line_id, arc), rel, leg["i0"] + i, leg["i0"] + i + 1,
					minf(v_kmh, 350.0))
	# 已驶离本腿末端（时间缝隙由 transfer 分支处理，此处兜底收车）
	return {"code": train["code"], "status": "done"}


func _transfer_state(train: Dictionary, tr: Dictionary, rel: float,
		next_leg: Dictionary) -> Dictionary:
	var span: float = maxf(tr["t1_rel"] - tr["t0_rel"], 1.0)
	var f := clampf((rel - tr["t0_rel"]) / span, 0.0, 1.0)
	var pos: Vector2 = tr["pos_a"].lerp(tr["pos_b"], f)
	var dirv: Vector2 = (tr["pos_b"] - tr["pos_a"]).normalized()
	if dirv.length_squared() < 0.5:
		dirv = Vector2.RIGHT
	var dist_km: float = tr["pos_a"].distance_to(tr["pos_b"]) / 1000.0
	var dur_h: float = span / 3600.0
	var v_kmh: float = dist_km / maxf(dur_h, 0.01)
	var next_stop: Dictionary = train["stops"][next_leg["i0"]]
	return _mk_state(train, str(next_stop.get("line", "")), "run", pos, dirv,
			DB.km_at_arc(str(next_stop.get("line", "")), next_leg["arc0"]), rel,
			next_leg["i0"], next_leg["i0"] + 1, minf(v_kmh, 350.0))


func _state_at_stop(train: Dictionary, line_id: String, stop: Dictionary,
		rel: float, stop_idx: int, next_idx: int) -> Dictionary:
	var pt := DB.arc_point(line_id, stop["arc"])
	var dirv: Vector2 = _probe_dir(line_id, stop["arc"], null)
	return _mk_state(train, line_id, "stop", pt["pos"], dirv,
			DB.km_at_arc(line_id, stop["arc"]), rel, stop_idx, next_idx, 0.0)


# 箭头朝向探测：沿行驶方向取前方 80m 采样（与 down=弧长递增同一套定义）
func _probe_dir(line_id: String, arc: float, leg) -> Vector2:
	var sign := 1.0
	if leg != null:
		sign = 1.0 if leg["arc1"] > leg["arc0"] else -1.0
	var pt := DB.arc_point(line_id, arc)
	var pt2 := DB.arc_point(line_id, arc + 80.0 * sign)
	var dv: Vector2 = pt2["pos"] - pt["pos"]
	if dv.length_squared() > 1.0:
		return dv.normalized()
	return pt["dir"]


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

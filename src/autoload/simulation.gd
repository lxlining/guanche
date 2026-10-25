# 仿真内核：时刻表 + 几何 -> 任意游戏时刻的列车状态。
# 状态为纯函数式解算（time -> state），天然支持任意倍速与时间跳转。
extends Node

const WAIT_WINDOW := 1800.0  # 发车前 30 分钟在始发站显示「待发」

var states: Dictionary = {}  # code -> 状态字典（当前时刻）


func _process(_delta: float) -> void:
	var t := GameTime.t
	for train in DB.trains:
		states[train["code"]] = state_for(train, t)


# 纯解算：给定列车与时刻，返回状态。
# status: off(未上线/已收车) / wait(始发待发) / run(区间运行) / stop(停站) / done(终到)
func state_for(train: Dictionary, t: float) -> Dictionary:
	var rel := fposmod(t - train["start_s"], 86400.0)
	var dur: float = train["run_dur"]
	var stops: Array = train["stops"]

	if rel > dur:
		if rel >= 86400.0 - WAIT_WINDOW:
			return _mk_state(train, "wait", stops[0]["arc"], rel, 0, 0)
		return {"code": train["code"], "status": "off"}

	var segs: Array = train["segs"]
	for i in range(stops.size()):
		if rel < stops[i]["dep_rel"]:
			if rel >= stops[i]["arr_rel"]:
				return _mk_state(train, "stop", stops[i]["arc"], rel, i, i + 1)
			# 区间运行：segs[i-1] 连接 stops[i-1] -> stops[i]
			var seg: Dictionary = segs[i - 1]
			var tau: float = (rel - stops[i - 1]["dep_rel"]) / maxf(stops[i]["arr_rel"] - stops[i - 1]["dep_rel"], 1.0)
			var p := _trapezoid_progress(tau, seg["accel"])
			var arc: float = lerpf(seg["arc0"], seg["arc1"], p)
			var slope := _trapezoid_slope(tau, seg["accel"])
			var v_kmh: float = seg["len_m"] / maxf(seg["dur_s"], 1.0) * slope * 3.6
			return _mk_state(train, "run", arc, rel, i, i, v_kmh)
	# 已驶离最后一站
	return {"code": train["code"], "status": "done"}


func _mk_state(train: Dictionary, status: String, arc: float, rel: float,
		stop_idx: int, next_idx: int, v_kmh: float = 0.0) -> Dictionary:
	var pt := DB.arc_point(arc)
	var dirv: Vector2 = pt["dir"]
	var dir_sign := 1.0 if train["dir"] == "down" else -1.0
	var pt2 := DB.arc_point(arc + 80.0 * dir_sign)
	var dv: Vector2 = pt2["pos"] - pt["pos"]
	if dv.length_squared() > 1.0:
		dirv = dv.normalized()
	var stops: Array = train["stops"]
	var st := {
		"code": train["code"], "type": train["type"], "dir": train["dir"],
		"status": status, "arc": arc, "pos": pt["pos"], "dirv": dirv,
		"speed_kmh": minf(v_kmh, 350.0), "km": DB.km_at_arc(arc),
		"rel": rel, "stop_idx": stop_idx
	}
	if next_idx >= 0 and next_idx < stops.size():
		st["next_sid"] = stops[next_idx]["sid"]
		st["next_arr_s"] = stops[next_idx]["arr_s"]
	else:
		st["next_sid"] = ""
		st["next_arr_s"] = -1.0
	return st


# 梯形速度包络：加速占比 a，位置进度 p(tau)（恰好覆盖 0..1）
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

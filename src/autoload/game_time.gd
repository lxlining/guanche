# 游戏时钟：一天循环（0~86400 游戏秒），可暂停/倍速/跳转。
extends Node

signal jumped
signal speed_changed

var t: float = 25200.0  # 默认 07:00，正好赶上早高峰
var speed: float = 60.0
var paused: bool = false


func _process(delta: float) -> void:
	if not paused and speed > 0.0:
		t = fposmod(t + delta * speed, 86400.0)


func set_speed(s: float) -> void:
	speed = s
	paused = false
	speed_changed.emit()


func toggle_pause() -> void:
	paused = not paused
	speed_changed.emit()


func jump_to(h: int, m: int) -> void:
	t = fposmod(float(h * 3600 + m * 60), 86400.0)
	jumped.emit()


func jump_to_seconds(sec: float) -> void:
	t = fposmod(sec, 86400.0)
	jumped.emit()


func hour() -> int:
	return int(t / 3600.0)


func minute() -> int:
	return int(fmod(t, 3600.0) / 60.0)


func time_string() -> String:
	var total := int(t)
	return "%02d:%02d" % [int(t / 3600.0), int(fmod(float(total), 3600.0) / 60.0)]


func time_string_full() -> String:
	var total := int(t)
	return "%02d:%02d:%02d" % [int(t / 3600.0), int(fmod(float(total), 3600.0) / 60.0), total % 60]


# 时刻 "HH:MM" -> 当日秒数
static func parse_hhmm(s: String) -> float:
	var parts := s.split(":")
	if parts.size() < 2:
		return 0.0
	return float(int(parts[0]) * 3600 + int(parts[1]) * 60)


# 圆环上两时刻的最小间隔（秒）
static func circular_diff(a: float, b: float) -> float:
	var d := absf(fposmod(a - b, 86400.0))
	return minf(d, 86400.0 - d)


# 绝对秒（可超过 86400，表示次日）-> "HH:MM"，跨日加 "+1"
static func fmt_hhmm_abs(sec: float) -> String:
	var day := int(sec / 86400.0)
	var tt := fposmod(sec, 86400.0)
	var base := "%02d:%02d" % [int(tt / 3600.0), int(fmod(tt, 3600.0) / 60.0)]
	if day > 0:
		return base + " +1"
	return base

# 临时性能插桩（PERF=1 启用）：每 120 帧打印各子系统耗时分布。
extends Node

var _accum := {}
var _counts := {}
var _frames := 0
var _enabled := false


func _ready() -> void:
	_enabled = OS.get_environment("PERF") == "1"
	set_process(_enabled)


func lap(key: String, us: int) -> void:
	if _enabled:
		_accum[key] = int(_accum.get(key, 0)) + us
		_counts[key] = int(_counts.get(key, 0)) + 1


func _process(_delta: float) -> void:
	_frames += 1
	if _frames % 40 != 0:
		return
	var parts := []
	var order := _accum.keys()
	order.sort_custom(func(a, b): return int(_accum[b]) > int(_accum[a]))
	for k in order:
		parts.append("%s=%dms(%d次)" % [k, int(_accum[k]) / 120, int(_counts[k])])
	print("[PERF] frames=", _frames, "  ", " ".join(parts))
	_accum = {}
	_counts = {}

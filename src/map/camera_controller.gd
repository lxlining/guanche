# 相机控制：拖拽平移、滚轮以鼠标为中心缩放、边界钳制、跟随列车。
extends Camera2D

signal map_clicked(world_pos: Vector2)
signal map_right_clicked(world_pos: Vector2)

var min_zoom := 0.0006
var max_zoom := 2.0
var follow_code := ""

var _dragging := false
var _drag_moved := false


func _ready() -> void:
	make_current()
	position = DB.map_center
	var z: float = clampf(DB.fit_zoom, min_zoom, max_zoom)
	zoom = Vector2(z, z)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(1.10)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(1.0 / 1.10)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_moved = false
			else:
				if _dragging and not _drag_moved:
					map_clicked.emit(get_global_mouse_position())
				_dragging = false
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = event.pressed
			_drag_moved = true
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			map_right_clicked.emit(get_global_mouse_position())
	elif event is InputEventMouseMotion and _dragging:
		position -= event.relative / zoom.x
		if event.relative.length() > 2.0:
			_drag_moved = true
			if follow_code != "":
				follow_code = ""
		_clamp_position()


func _process(delta: float) -> void:
	if follow_code != "":
		var st = Simulation.states.get(follow_code)
		if st != null and st.has("pos"):
			var w := 1.0 - pow(0.002, delta)
			position = position.lerp(st["pos"], clampf(w, 0.0, 1.0))
			_clamp_position()


func _zoom_at(f: float) -> void:
	var pos_old := position
	var z_old := zoom.x
	var mu := get_global_mouse_position()
	var z_new := clampf(z_old * f, min_zoom, max_zoom)
	if is_equal_approx(z_new, z_old):
		return
	zoom = Vector2(z_new, z_new)
	position = mu - (mu - pos_old) * (z_old / z_new)
	if follow_code != "":
		follow_code = ""
	_clamp_position()


func _clamp_position() -> void:
	var margin: Vector2 = DB.map_size * 0.55
	var lo := DB.map_center - margin
	var hi := DB.map_center + margin
	position = position.clamp(lo, hi)

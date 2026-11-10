# 相机控制：拖拽平移、滚轮以鼠标为中心平滑缩放（指数缓动 + 锚点保持）、
# 双击放大、键盘 +/-、边界钳制、跟随列车。
extends Camera2D

signal map_clicked(world_pos: Vector2)
signal map_right_clicked(world_pos: Vector2)

var min_zoom := 0.0006
var max_zoom := 2.0
var follow_code := ""

var _dragging := false
var _drag_moved := false
var _tz := -1.0               # 平滑缩放目标（-1 = 无动画）
var _anchor_screen := Vector2.ZERO
var _anchor_world := Vector2.ZERO


func _ready() -> void:
	make_current()
	position = DB.map_center
	var z: float = clampf(DB.fit_zoom, min_zoom, max_zoom)
	zoom = Vector2(z, z)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(1.18)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(1.0 / 1.18)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click:
					# 双击放大：以点击处为锚点 ×1.8（不进入拖拽）
					var mu := get_global_mouse_position()
					_start_zoom_anim(zoom.x * 1.8, mu, mu)
				else:
					_tz = -1.0
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
		_tz = -1.0
		position -= event.relative / zoom.x
		if event.relative.length() > 2.0:
			_drag_moved = true
			if follow_code != "":
				follow_code = ""
		_clamp_position()


func _process(delta: float) -> void:
	if _tz > 0.0 and not is_equal_approx(zoom.x, _tz):
		# 指数缓动逼近目标 zoom；锚点地理点在动画期间保持屏幕位置稳定
		var w := 1.0 - pow(0.0002, delta)
		var z_new := lerpf(zoom.x, _tz, clampf(w, 0.0, 1.0))
		zoom = Vector2(z_new, z_new)
		var vp := get_viewport().get_visible_rect().size
		position = _anchor_world - (_anchor_screen - vp * 0.5) / z_new
		if follow_code != "":
			follow_code = ""
		_clamp_position()
		if absf(zoom.x - _tz) / _tz < 0.008:
			zoom = Vector2(_tz, _tz)
			_tz = -1.0
	if follow_code != "":
		var st = Simulation.states.get(follow_code)
		if st != null and st.has("pos"):
			var w := 1.0 - pow(0.002, delta)
			position = position.lerp(st["pos"], clampf(w, 0.0, 1.0))
			_clamp_position()


# 统一缩放入口：factor 相对缩放，anchor_screen 屏幕锚点，anchor_world 锚点地理点
func _start_zoom_anim(z_target: float, anchor_screen: Vector2, anchor_world: Vector2) -> void:
	z_target = clampf(z_target, min_zoom, max_zoom)
	if z_target <= 0.0:
		return
	_tz = z_target
	_anchor_screen = anchor_screen
	_anchor_world = anchor_world
	if follow_code != "":
		follow_code = ""


func _zoom_at(f: float) -> void:
	var mu := get_global_mouse_position()
	var vp := get_viewport().get_visible_rect().size
	if _tz > 0.0:
		# 动画中再次滚动：锚点取「鼠标屏幕位置在目标 zoom 下」的地理点（延续不漂移）
		var aw := position + (mu - vp * 0.5) / _tz
		_start_zoom_anim(_tz * f, mu, aw)
	else:
		_start_zoom_anim(zoom.x * f, mu, mu)


# UI 缩放按钮 / 键盘入口：以屏幕中心为锚点
func zoom_step(f: float) -> void:
	var vp := get_viewport().get_visible_rect().size
	var aw := position + (vp * 0.5) / (_tz if _tz > 0.0 else zoom.x)
	_start_zoom_anim((_tz if _tz > 0.0 else zoom.x) * f, vp * 0.5, aw)


func zoom_reset_nation() -> void:
	_tz = -1.0
	follow_code = ""
	position = DB.map_center
	zoom = Vector2(DB.fit_zoom, DB.fit_zoom)


func _clamp_position() -> void:
	var margin: Vector2 = DB.map_size * 0.55
	var lo := DB.map_center - margin
	var hi := DB.map_center + margin
	position = position.clamp(lo, hi)

# 观测机位层：绘制玩家放置的「拍车机位」及其覆盖圈，机位模式下显示放置预览。
extends Node2D

var _mouse_world := Vector2.ZERO


func _ready() -> void:
	Meta.spots_changed.connect(queue_redraw)
	Meta.spot_mode_changed.connect(func(_on: bool): queue_redraw())


func _process(_delta: float) -> void:
	_mouse_world = get_global_mouse_position()
	queue_redraw()


func _draw() -> void:
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	var px := 1.0 / zoom

	for s in Meta.spots:
		var pos: Vector2 = s["world"]
		var r: float = s["r_m"]
		draw_circle(pos, r, Color(0.36, 0.55, 0.95, 0.08))
		draw_arc(pos, r, 0.0, TAU, 72, Color(0.45, 0.62, 0.95, 0.55), 1.5 * px, true)
		draw_set_transform(pos, 0.0, Vector2.ONE * px)
		draw_rect(Rect2(-10, -8, 20, 16), Color(0.13, 0.17, 0.24, 0.95), true)
		draw_rect(Rect2(-10, -8, 20, 16), Color(0.55, 0.75, 1.0), false, 1.6)
		draw_circle(Vector2.ZERO, 4.2, Color(0.55, 0.75, 1.0))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# 机位文字由 LabelLayer（屏幕空间）绘制

	if Meta.spot_mode:
		draw_arc(_mouse_world, 0.85 * Meta.SPOT_RADIUS_M, 0.0, TAU, 48,
				Color(0.5, 0.68, 1.0, 0.35), 1.5 * px, true)
		draw_circle(_mouse_world, 4.0 * px, Color(0.5, 0.68, 1.0, 0.6))

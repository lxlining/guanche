# 航线弧线层：航空模式开启时绘制全国航线大圆弧（航司配色、LOD 采样）。
# 弧线不动，仅在开启状态/缩放显著变化时重绘，不逐帧开销。
# 性能：按航司颜色把全部弧段合并成少量 draw_multiline 批次（10 色 → 10 个 draw call），
# 避免逐航线 draw_polyline 造成的数千 draw call。
extends Node2D

var _last_on := false
var _last_zoom := -1.0


func _process(_delta: float) -> void:
	var on: bool = Meta.aviation_on and FlightSim.ready_ok
	# 每帧显式设置可见性：节点默认 visible=true，若仅在「变化分支」里
	# 赋值，航空模式从关启动时永不进入分支——入树自动绘帧会用启动瞬间
	# 的 px 画出横跨全屏的巨型蓝条
	visible = on
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	if on != _last_on or (on and absf(zoom - _last_zoom) > _last_zoom * 0.12):
		_last_on = on
		_last_zoom = zoom
		queue_redraw()


func _draw() -> void:
	if not visible:
		return
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	if zoom > 0.05:
		return  # 近景只看列车与机场，弧线是噪音
	var lod := 8 if zoom < 0.004 else (16 if zoom < 0.012 else 24)
	# 统一天蓝弧网（经典航线图风格）；全国视野略去 <250km 短线防糊
	# 线宽随相机缩放：width 是世界单位，须乘 px 才能保持屏幕像素恒定
	var alpha := 0.26 if zoom < 0.004 else (0.32 if zoom < 0.012 else 0.4)
	var px := 1.0 / maxf(zoom, 1.0e-6)
	var w := (1.2 if lod < 24 else 1.1) * px
	var skip_km := 250.0 if lod == 8 else 0.0
	var arc_col := Color(0.45, 0.72, 1.0, alpha)
	# 按颜色收集线段：每条路径展开为成对端点
	var segs := PackedVector2Array()
	for ri in range(FlightSim.routes.size()):
		var r: Dictionary = FlightSim.routes[ri]
		if skip_km > 0.0 and r["dist_km"] < skip_km:
			continue
		var pts: PackedVector2Array = r["path8"] if lod == 8 else (r["path16"] if lod == 16 else r["path"])
		for i in range(1, pts.size()):
			segs.append(pts[i - 1])
			segs.append(pts[i])
	if segs.size() >= 2:
		draw_multiline(segs, arc_col, w, false)
	if OS.get_environment("ARC_DEBUG") != "":
		print("[arc] draw visible=%s zoom=%.5f lod=%d segs=%d alpha=%.2f" %
				[visible, zoom, lod, segs.size(), alpha])

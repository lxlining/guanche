# 航线弧线层：航空模式开启时绘制全国航线大圆弧（航司配色、LOD 采样）。
# 弧线不动，仅在开启状态/缩放显著变化时重绘，不逐帧开销。
# 性能：按航司颜色把全部弧段合并成少量 draw_multiline 批次（10 色 → 10 个 draw call），
# 避免逐航线 draw_polyline 造成的数千 draw call。
extends Node2D

var _last_on := false
var _last_zoom := -1.0


func _process(_delta: float) -> void:
	var on: bool = Meta.aviation_on and FlightSim.ready_ok and not Meta.focus_active()
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	if on != _last_on or (on and absf(zoom - _last_zoom) > _last_zoom * 0.12):
		_last_on = on
		_last_zoom = zoom
		visible = on
		queue_redraw()


func _draw() -> void:
	if not visible:
		return
	var cam := get_viewport().get_camera_2d()
	var zoom := cam.zoom.x if cam != null else DB.fit_zoom
	if zoom > 0.05:
		return  # 近景只看列车与机场，弧线是噪音
	var lod := 8 if zoom < 0.004 else (16 if zoom < 0.012 else 24)
	var alpha := 0.22 if zoom < 0.004 else (0.22 if zoom < 0.012 else 0.26)
	var w := 1.2 if lod < 24 else 1.0
	var skip_km := 350.0 if lod == 8 else 700.0
	# 按颜色收集线段：每条路径展开为成对端点
	var segs: Dictionary = {}   # color_str -> PackedVector2Array
	for ri in range(FlightSim.routes.size()):
		var r: Dictionary = FlightSim.routes[ri]
		if lod < 24 and r["dist_km"] < skip_km:
			continue  # 低倍视野略去短航线，突出干线
		var pts: PackedVector2Array = r["path8"] if lod == 8 else (r["path16"] if lod == 16 else r["path"])
		var al: Dictionary = FlightSim.airlines.get(str(r["airline"]), {})
		var key := str(al.get("color", "#5b7fe0"))
		var arr: PackedVector2Array = segs.get(key, PackedVector2Array())
		for i in range(1, pts.size()):
			arr.append(pts[i - 1])
			arr.append(pts[i])
		segs[key] = arr
	for key in segs:
		var col := Color(key)
		col.a = alpha
		draw_multiline(segs[key], col, w, true)

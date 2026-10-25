# 简单等距圆柱投影：经纬度 <-> 世界坐标（米）。
# 以线路中心纬度做 cos 修正，保证南北向比例真实。
extends RefCounted

const LAT0 := 35.5
const LON0 := 118.85
const M_PER_DEG_LAT := 110574.0
# 111320.0 * cos(35.5°)，写成常量避免常量表达式调用函数
const M_PER_DEG_LON := 90627.0


static func lonlat_to_world(lon: float, lat: float) -> Vector2:
	return Vector2((lon - LON0) * M_PER_DEG_LON, -(lat - LAT0) * M_PER_DEG_LAT)


static func world_to_lonlat(p: Vector2) -> Vector2:
	return Vector2(LON0 + p.x / M_PER_DEG_LON, LAT0 - p.y / M_PER_DEG_LAT)


static func lonlat_dist_m(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
	var a := lonlat_to_world(lon1, lat1)
	var b := lonlat_to_world(lon2, lat2)
	return a.distance_to(b)

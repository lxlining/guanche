# 航班详情卡：航班号/航司/起降机场/阶段/高度速度/进度条/时刻，
# 动态字段每帧就地刷新，静态部分仅在切换航班时重建。支持跟随。
extends PanelContainer

const UIKit := preload("res://src/ui/ui_kit.gd")

signal follow_requested(idx: int)

var title_label: Label
var al_label: Label
var route_label: Label
var state_label: Label
var prog_bar: ProgressBar
var stat_label: Label
var time_label: Label
var seen_label: Label
var follow_btn: Button
var cur_idx := -1
var following := false
var _built_for := -1

const PHASE_TXT := {
	"pre": ["⏳ 值机 / 待起飞", Color("8b96a8")],
	"climb": ["🛫 爬升中", Color("e8a33d")],
	"cruise": ["✈️ 巡航中", Color("67c987")],
	"descend": ["🛬 下降中", Color("8f9dff")],
	"done": ["🛄 已到达", Color("8b96a8")],
}


func _ready() -> void:
	add_theme_stylebox_override("panel", UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 14))
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	grow_vertical = Control.GROW_DIRECTION_BOTH
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	custom_minimum_size = Vector2(340, 0)
	visible = false

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	title_label = UIKit.label("航班", 20, Color.WHITE)
	head.add_child(title_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	follow_btn = UIKit.button("跟随 [F]", func(): follow_requested.emit(cur_idx))
	follow_btn.custom_minimum_size = Vector2(84, 26)
	head.add_child(follow_btn)
	var close_btn := UIKit.button("×", func(): hide())
	close_btn.custom_minimum_size = Vector2(30, 26)
	head.add_child(close_btn)

	al_label = UIKit.label("", 13, UIKit.ACCENT2)
	vb.add_child(al_label)
	route_label = UIKit.label("", 17, Color.WHITE)
	vb.add_child(route_label)
	state_label = UIKit.label("", 13, UIKit.WARN)
	vb.add_child(state_label)
	prog_bar = ProgressBar.new()
	prog_bar.min_value = 0.0
	prog_bar.max_value = 1.0
	prog_bar.show_percentage = false
	prog_bar.custom_minimum_size = Vector2(320, 8)
	prog_bar.add_theme_stylebox_override("background", UIKit.flat(Color("0f141d"), 4))
	prog_bar.add_theme_stylebox_override("fill", UIKit.flat(UIKit.ACCENT2, 4))
	vb.add_child(prog_bar)
	stat_label = UIKit.label("", 12, UIKit.TEXT)
	vb.add_child(stat_label)
	time_label = UIKit.label("", 12, UIKit.DIM)
	vb.add_child(time_label)
	seen_label = UIKit.label("", 11, UIKit.DIM)
	vb.add_child(seen_label)


func show_flight(idx: int) -> void:
	cur_idx = idx
	visible = true
	_built_for = -1
	_refresh(true)


func clear_flight() -> void:
	cur_idx = -1
	visible = false


func set_following(on: bool) -> void:
	following = on
	follow_btn.text = "跟随中…" if on else "跟随 [F]"


func _process(_delta: float) -> void:
	if visible and cur_idx >= 0:
		_refresh(false)


func _refresh(force: bool) -> void:
	if cur_idx < 0 or cur_idx >= FlightSim.flights.size():
		return
	var fl: Dictionary = FlightSim.flights[cur_idx]
	var st: Dictionary = FlightSim.state_for(cur_idx, GameTime.t)
	if force or _built_for != cur_idx:
		_built_for = cur_idx
		title_label.text = str(fl["id"])
		var al: Dictionary = FlightSim.airlines.get(str(fl["al"]), {"name": "", "color": "#ffffff"})
		al_label.text = "%s · %s → %s (%s → %s)" % [str(al["name"]),
				FlightSim.airports[fl["from"]]["city"], FlightSim.airports[fl["to"]]["city"],
				str(fl["from"]), str(fl["to"])]
		var col := Color(str(al["color"]))
		al_label.add_theme_color_override("font_color", col.lightened(0.3))
		route_label.text = "%s → %s" % [FlightSim.airports[fl["from"]]["name"],
				FlightSim.airports[fl["to"]]["name"]]
		var dur_min := int(float(fl["dur"]) / 60.0)
		time_label.text = "起飞 %s · 到达 %s · 全程 %d 分钟" % [
				GameTime.fmt_hhmm_abs(float(fl["dep"])),
				GameTime.fmt_hhmm_abs(float(fl["dep"]) + float(fl["dur"])), dur_min]
		var fid: String = str(fl["id"])
		var n: int = int(Meta.flights_seen.get(fid, 0))
		seen_label.text = "已观测 ×%d" % n if n > 0 else ""
	if following:
		set_following(true)
	var ph: String = str(st["phase"])
	var pd: Array = PHASE_TXT.get(ph, ["—", UIKit.DIM])
	state_label.text = str(pd[0])
	state_label.add_theme_color_override("font_color", pd[1])
	prog_bar.value = float(st["prog"])
	if ph == "pre":
		stat_label.text = "距起飞 %.0f 分钟" % (float(st["remain"]) / 60.0)
	elif ph == "done":
		stat_label.text = "航班已完成（明日同时刻再飞）"
	else:
		stat_label.text = "高度 %.1f km · 地速 %d km/h · 余 %d 分钟" % [
				float(st["alt"]) / 1000.0, int(float(st["speed"])), int(float(st["remain"]) / 60.0)]


func phase_is_airborne() -> bool:
	if cur_idx < 0 or cur_idx >= FlightSim.flights.size():
		return false
	var ph: String = str(FlightSim.state_for(cur_idx, GameTime.t)["phase"])
	return ph == "climb" or ph == "cruise" or ph == "descend"

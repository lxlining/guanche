# 站点信息卡：点击车站显示简介（所属线路、公里标、日均停靠车次、
# 大站附一句人工简介）。
extends PanelContainer

const UIKit := preload("res://src/ui/ui_kit.gd")

var title_label: Label
var lines_label: Label
var stats_label: Label
var desc_label: RichTextLabel


const INTROS := {
	"北京南": "京沪高铁与京津城际的起点站，亚洲最繁忙的铁路枢纽之一，24 座站台的超级车站。",
	"上海虹桥": "京沪高铁终点与虹桥综合交通枢纽核心，高铁、机场、地铁无缝衔接。",
	"南京南": "京沪高铁、宁杭、宁安、沿江通道交汇的华东枢纽，15 台 28 线。",
	"济南西": "京沪高铁中段枢纽，济青高铁与郑济方向的接入点。",
	"徐州东": "京沪与徐兰两大干线十字交汇，「五省通衢」的枢纽。",
	"郑州东": "米字形高铁网的正中心，京广、徐兰、郑渝、郑阜、济郑在此交汇。",
	"武汉": "九省通衢，京广高铁与沿江通道的十字路口。",
	"长沙南": "京广高铁与沪昆高铁交汇点，中部最大高铁枢纽之一。",
	"广州南": "京广高铁终点、广深港与贵广、南广起点，全国客流量最大的车站之一。",
	"深圳北": "广深港高铁与杭深线交汇的深圳主枢纽。",
	"西安北": "徐兰、西成、西银、大西四线交汇的西北最大枢纽，18 台 34 线。",
	"成都东": "西成、成贵、成渝、沿江通道汇聚的西部第一大站。",
	"重庆北": "沿江通道、郑渝、成渝在山城交汇的枢纽。",
	"贵阳北": "沪昆、贵广、成贵、渝贵交汇，「十字型」高铁枢纽。",
	"昆明南": "沪昆高铁终点、南昆通道起点，面向东南亚的门户枢纽。",
	"兰州西": "徐兰高铁终点、兰新起点，西北铁路网的核心。",
	"乌鲁木齐": "兰新高铁终点，亚洲内陆最大的铁路枢纽之一。",
	"哈尔滨西": "京哈、哈大高铁交汇点，东北北部枢纽。",
	"沈阳北": "京哈、哈大交汇的东北第一大枢纽。",
	"天津": "京津城际终点、京沪线上重要枢纽，百年老站（1892 年始建）。",
	"北京西": "京广高铁与京广线起点，1996 年启用的特大型车站。",
	"杭州东": "沪昆、宁杭、杭深、商合杭交汇，长三角第二大枢纽。",
	"合肥南": "合福、商合杭、沿江通道交汇的安徽枢纽。",
	"福州": "杭深线与合福高铁终点，海峡西岸枢纽。",
	"厦门北": "杭深线上的厦门主枢纽。",
	"香港西九龙": "广深港高铁终点，实行「一地两检」的跨境车站。",
	"拉萨": "青藏铁路终点，世界海拔最高的大型车站（3641 米）。",
	"张家界西": "张吉怀高铁起点，通往湘西名胜的门户。",
	"三亚": "海南环岛高铁的南端终点，热带滨海旅游门户。",
	"青岛北": "济青高铁终点与青盐线交汇点。",
}


func _ready() -> void:
	add_theme_stylebox_override("panel", UIKit.flat(UIKit.BG, 12, UIKit.BORDER, 1, 14))
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 14)
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size = Vector2(360, 0)
	visible = false

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	add_child(vb)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	vb.add_child(head)
	title_label = UIKit.label("车站", 22, Color.WHITE)
	head.add_child(title_label)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var close_btn := UIKit.button("×", func(): hide())
	close_btn.custom_minimum_size = Vector2(30, 26)
	head.add_child(close_btn)

	lines_label = UIKit.label("", 13, UIKit.ACCENT2)
	lines_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(lines_label)
	stats_label = UIKit.label("", 12, UIKit.TEXT)
	vb.add_child(stats_label)
	desc_label = RichTextLabel.new()
	desc_label.bbcode_enabled = true
	desc_label.fit_content = true
	desc_label.custom_minimum_size = Vector2(330, 0)
	desc_label.add_theme_color_override("default_color", UIKit.TEXT)
	vb.add_child(desc_label)


func show_station(station_name: String, line_names: Array, km: int,
		daily_stops: int, major: bool) -> void:
	title_label.text = station_name + ("　●枢纽" if major else "")
	lines_label.text = "所属线路：" + "、".join(line_names)
	stats_label.text = "公里标 K%d · 日均停靠约 %d 趟" % [km, daily_stops]
	var intro: String = INTROS.get(station_name, "")
	if intro != "":
		desc_label.text = "[color=#8b96a8]" + intro + "[/color]"
		desc_label.visible = true
	else:
		desc_label.text = ""
		desc_label.visible = false
	visible = true

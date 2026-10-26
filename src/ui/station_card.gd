# 站点信息卡（可编辑版）：显示站点简介/图片，支持用户编辑文字与添加
# 本地图片。用户内容保存在 user://station_content/<站名>.json，
# 图片复制到 user://station_images/<站名>/，与内置 INTROS 合并展示。
extends PanelContainer

const UIKit := preload("res://src/ui/ui_kit.gd")

const CONTENT_DIR := "user://station_content"
const IMG_DIR := "user://station_images"

var title_label: Label
var lines_label: Label
var stats_label: Label
var desc_label: RichTextLabel
var images_row: HBoxContainer
var edit_toggle_btn: Button
var edit_box: VBoxContainer
var text_edit: TextEdit
var add_img_btn: Button
var save_btn: Button

var cur_name := ""
var cur_lines: Array = []
var cur_km := 0
var cur_stops := 0
var cur_major := false
var user_text := ""
var user_images: Array = []
var editing := false


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
	custom_minimum_size = Vector2(370, 0)
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
	var edit_btn := UIKit.button("✏ 编辑", func(): _toggle_edit())
	edit_btn.custom_minimum_size = Vector2(64, 26)
	head.add_child(edit_btn)
	var close_btn := UIKit.button("×", func(): hide())
	close_btn.custom_minimum_size = Vector2(30, 26)
	head.add_child(close_btn)

	lines_label = UIKit.label("", 13, UIKit.ACCENT2)
	lines_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(lines_label)
	stats_label = UIKit.label("", 12, UIKit.TEXT)
	vb.add_child(stats_label)

	images_row = HBoxContainer.new()
	images_row.add_theme_constant_override("separation", 6)
	images_row.visible = false
	vb.add_child(images_row)

	desc_label = RichTextLabel.new()
	desc_label.bbcode_enabled = true
	desc_label.fit_content = true
	desc_label.custom_minimum_size = Vector2(340, 0)
	desc_label.add_theme_color_override("default_color", UIKit.TEXT)
	vb.add_child(desc_label)

	edit_box = VBoxContainer.new()
	edit_box.add_theme_constant_override("separation", 4)
	edit_box.visible = false
	vb.add_child(edit_box)
	var hint := UIKit.label("输入你的介绍/拍车笔记（保存在本机，仅自己可见）：", 11, UIKit.DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	edit_box.add_child(hint)
	text_edit = TextEdit.new()
	text_edit.custom_minimum_size = Vector2(340, 90)
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit_box.add_child(text_edit)
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	edit_box.add_child(btns)
	add_img_btn = UIKit.button("📷 添加图片", func(): _pick_image())
	btns.add_child(add_img_btn)
	save_btn = UIKit.button("💾 保存", func(): _save_content(), "primary")
	btns.add_child(save_btn)


func show_station(station_name: String, line_names: Array, km: int,
		daily_stops: int, major: bool) -> void:
	cur_name = station_name
	cur_lines = line_names
	cur_km = km
	cur_stops = daily_stops
	cur_major = major
	_toggle_edit(false)
	_reload()
	visible = true


func _reload() -> void:
	title_label.text = cur_name + ("　●枢纽" if cur_major else "")
	lines_label.text = ("所属线路：" + "、".join(cur_lines)) if not cur_lines.is_empty() else "所属线路：—"
	stats_label.text = "公里标 K%d · 日均停靠约 %d 趟" % [cur_km, cur_stops]

	user_text = ""
	user_images = []
	var upath := CONTENT_DIR + "/" + cur_name + ".json"
	if FileAccess.file_exists(upath):
		var parsed = JSON.parse_string(FileAccess.open(upath, FileAccess.READ).get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			user_text = str(parsed.get("text", ""))
			for img in parsed.get("images", []):
				user_images.append(str(img))

	var intro: String = INTROS.get(cur_name, "")
	var parts: Array = []
	if intro != "":
		parts.append("[color=#8b96a8]" + intro + "[/color]")
	if user_text != "":
		parts.append("[color=#dbe2ee]" + user_text + "[/color]")
	desc_label.text = "\n".join(parts)
	desc_label.visible = not parts.is_empty()

	for c in images_row.get_children():
		c.queue_free()
	images_row.visible = not user_images.is_empty()
	for img_path in user_images:
		if not FileAccess.file_exists(img_path):
			continue
		var img := Image.load_from_file(img_path)
		if img == null:
			continue
		var tex := ImageTexture.create_from_image(img)
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.custom_minimum_size = Vector2(105, 78)
		images_row.add_child(tr)
	editing = false
	edit_box.visible = false


func _toggle_edit(force: bool = true) -> void:
	editing = force if force != editing else not editing
	edit_box.visible = editing
	if editing:
		text_edit.text = user_text if user_text != "" else INTROS.get(cur_name, "")


func _save_content() -> void:
	DirAccess.make_dir_recursive_absolute(CONTENT_DIR)
	var path := CONTENT_DIR + "/" + cur_name + ".json"
	var doc := {"text": text_edit.text, "images": user_images}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	_toggle_edit(false)
	_reload()


func _pick_image() -> void:
	var fd := FileDialog.new()
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.filters = ["*.png ; PNG 图片", "*.jpg ; JPEG 图片", "*.jpeg ; JPEG 图片"]
	add_child(fd)
	fd.file_selected.connect(func(path: String):
		var dir := IMG_DIR + "/" + cur_name
		DirAccess.make_dir_recursive_absolute(dir)
		var ext := path.get_extension()
		var dest := dir + "/img_%d.%s" % [Time.get_ticks_msec(), ext]
		var src := FileAccess.open(path, FileAccess.READ)
		var dst := FileAccess.open(dest, FileAccess.WRITE)
		dst.store_buffer(src.get_buffer(src.get_length()))
		dst.close()
		src.close()
		user_images.append(dest)
		DirAccess.make_dir_recursive_absolute(CONTENT_DIR)
		var cpath := CONTENT_DIR + "/" + cur_name + ".json"
		var f := FileAccess.open(cpath, FileAccess.WRITE)
		f.store_string(JSON.stringify({"text": user_text, "images": user_images}, "  "))
		f.close()
		_toggle_edit(false)
		_reload()
		fd.queue_free())
	fd.popup_centered(Vector2i(700, 500))

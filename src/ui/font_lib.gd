# 字体加载：优先使用打包的 Noto Sans SC，否则回退到系统中文字体。
extends RefCounted

const BUNDLED := "res://assets/fonts/NotoSansSC.ttf"

static var _cached: Font = null


static func get_font() -> Font:
	if _cached != null:
		return _cached
	if FileAccess.file_exists(BUNDLED):
		var f: Font = load(BUNDLED)
		if f != null:
			_cached = f
			return f
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC",
		"Noto Sans CJK SC", "Source Han Sans SC", "SimHei", "WenQuanYi Micro Hei"
	])
	_cached = sf
	return sf

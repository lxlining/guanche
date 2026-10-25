# UI 小组件工厂：统一暗色风格。
extends RefCounted

const BG := Color("141a24f2")
const BG2 := Color("0f141d")
const CARD := Color("18202e")
const BORDER := Color("2a3446")
const TEXT := Color("dbe2ee")
const DIM := Color("8b96a8")
const ACCENT := Color("5b6ee8")
const ACCENT2 := Color("8f9dff")
const GOOD := Color("67c987")
const WARN := Color("e8a33d")


static func flat(color: Color = BG, radius: int = 10, border: Color = Color.TRANSPARENT, bw: int = 0, margin: int = 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	if bw > 0:
		sb.set_border_width_all(bw)
		sb.border_color = border
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin - 2
	sb.content_margin_bottom = margin - 2
	return sb


static func label(text: String, size: int = 14, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, cb: Callable = Callable(), variant: String = "normal") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	var normal := flat(BG2, 8, BORDER, 1, 8)
	var hover := flat(Color("1c2636"), 8, ACCENT, 1, 8)
	var pressed := flat(ACCENT, 8, ACCENT2, 1, 8)
	if variant == "primary":
		normal = flat(ACCENT, 8, ACCENT2, 1, 8)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_font_size_override("font_size", 13)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func panel_container(style: StyleBoxFlat) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", style)
	return p


static func vspace(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


static func hspace(w: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, 0)
	return c

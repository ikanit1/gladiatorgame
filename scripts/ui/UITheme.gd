class_name UITheme
extends RefCounted

## Единый источник оформления интерфейса.
##
## До этого MainMenu и GameScreen собирали StyleBoxFlat поштучно прямо в местах
## использования. Из-за этого один и тот же «цвет панели» существовал в двух
## файлах, а любая правка оформления требовала обхода всех вызовов. Здесь стили
## собираются один раз и кешируются.
##
## Класс намеренно не автозагрузка: он ничего не хранит про состояние игры и
## нужен только двум экранам. Статические функции с ленивым кешем дают то же
## самое, но не занимают слот в списке автозагрузок и не создают узел в дереве.

# ------------------------------------------------------------------
# Палитра
# ------------------------------------------------------------------

const BG := Color("#12141a")        ## фон экрана
const PANEL := Color("#1b1f27")     ## подложка панели
const FG := Color("#e6e9ef")        ## основной текст
const DIM := Color("#8d95a5")       ## подписи и второстепенное
const ACCENT := Color("#d99a3c")    ## бронза: заголовки, ключевые значения
const DANGER := Color("#c8352c")    ## здоровье, урон, потеря
const GUARD := Color("#59a0d8")     ## щит
const ALLY := Color("#7a9e4b")      ## напарник
const GOOD := Color("#5fd39a")      ## подсказка о выходе, лечение

const ICON_DIR := "res://assets/ui/icons/"
const PANEL_FRAME := "res://assets/ui/panel_frame.png"
const BAR_FRAME := "res://assets/ui/bar_frame.png"
const MENU_BG := "res://assets/ui/menu_bg.png"

## Толщина рамки в пикселях исходной текстуры. Углы с заклёпками должны
## целиком попасть в угловые куски nine-slice, иначе заклёпка растянется
## вдоль стороны и превратится в размазанное пятно.
const PANEL_MARGIN := 16.0
## Обойма полосы сжата по вертикали (256x30, кант 3-4 пикселя), поэтому
## поля здесь маленькие. Сумма полей ОБЯЗАНА быть меньше высоты полосы:
## иначе Godot схлопывает центральный кусок, растягивает кромку на всю
## плашку и заливка перестаёт быть видна вовсе.
const BAR_MARGIN_X := 8.0
const BAR_MARGIN_Y := 5.0
## Минимальная высота полосы, при которой обойма ещё имеет смысл
const BAR_MIN_HEIGHT := 12

static var _icons: Dictionary = {}
static var _theme: Theme = null


# ------------------------------------------------------------------
# Ресурсы
# ------------------------------------------------------------------

## Иконка по имени без расширения: "sword", "helmet", "skull"...
##
## Глифы белые, поэтому красятся через modulate у самого TextureRect. Чёрные
## детали внутри глифа (глазницы черепа, умбон щита) при этом остаются
## тёмными и читаются как углубления - так и задумано.
static func icon(name: String) -> Texture2D:
	if _icons.has(name):
		return _icons[name]
	var path := ICON_DIR + name + ".svg"
	var tex: Texture2D = load(path) if ResourceLoader.exists(path) else null
	if tex == null:
		push_warning("UITheme: нет иконки %s" % path)
	_icons[name] = tex
	return tex


static func _texture(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null


# ------------------------------------------------------------------
# Стили
# ------------------------------------------------------------------

## Панель HUD: бронзовая рамка с заклёпками, тёмная середина.
##
## alpha < 1 приглушает панель целиком, вместе с рамкой - в бою сплошная
## непрозрачная плашка съедает угол экрана.
static func panel_style(alpha: float = 0.86) -> StyleBox:
	var tex := _texture(PANEL_FRAME)
	if tex == null:
		return _flat_fallback(alpha)

	var sb := StyleBoxTexture.new()
	sb.texture = tex
	sb.set_texture_margin_all(PANEL_MARGIN)
	sb.set_content_margin_all(14.0)
	sb.modulate_color = Color(1, 1, 1, alpha)
	# Края тянем, а не размножаем: бронза сделана однородной полосой, и
	# режим TILE давал бы заметный стык на длинной стороне панели.
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return sb


## Обойма полосы здоровья. draw_center выключен: заливку рисует отдельный
## узел под рамкой, и непрозрачная середина текстуры её бы перекрыла.
static func bar_frame_style() -> StyleBox:
	var tex := _texture(BAR_FRAME)
	if tex == null:
		var sb_flat := StyleBoxFlat.new()
		sb_flat.draw_center = false
		sb_flat.set_border_width_all(2)
		sb_flat.border_color = ACCENT.darkened(0.35)
		return sb_flat

	var sb := StyleBoxTexture.new()
	sb.texture = tex
	sb.texture_margin_left = BAR_MARGIN_X
	sb.texture_margin_right = BAR_MARGIN_X
	sb.texture_margin_top = BAR_MARGIN_Y
	sb.texture_margin_bottom = BAR_MARGIN_Y
	sb.draw_center = false
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	return sb


static func _flat_fallback(alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(PANEL.r, PANEL.g, PANEL.b, alpha)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(14.0)
	sb.border_color = ACCENT.darkened(0.45)
	sb.set_border_width_all(1)
	return sb


## Кнопка. primary - главное действие экрана, оно заливается бронзой.
static func button_style(primary: bool, state: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var base := ACCENT if primary else PANEL
	match state:
		"hover":
			base = base.lightened(0.14)
		"pressed":
			base = base.darkened(0.12)
	sb.bg_color = base
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10.0)
	# Тонкий бронзовый кант связывает кнопку с рамками панелей. У главной
	# кнопки он светлее фона, у остальных - сама бронза.
	sb.border_color = ACCENT.lightened(0.35) if primary else ACCENT.darkened(0.4)
	sb.set_border_width_all(1)
	if state == "hover":
		sb.border_color = ACCENT if not primary else ACCENT.lightened(0.6)
	return sb


# ------------------------------------------------------------------
# Тема
# ------------------------------------------------------------------

## Общая тема экранов. Назначается корневому Control: дочерние узлы
## наследуют её сами, поэтому per-widget override нужен только там, где
## оформление действительно отличается от общего.
static func theme() -> Theme:
	if _theme != null:
		return _theme

	var t := Theme.new()
	t.default_font_size = 15

	t.set_stylebox("panel", "PanelContainer", panel_style())
	t.set_stylebox("panel", "Panel", panel_style())

	t.set_stylebox("normal", "Button", button_style(false, "normal"))
	t.set_stylebox("hover", "Button", button_style(false, "hover"))
	t.set_stylebox("pressed", "Button", button_style(false, "pressed"))
	t.set_stylebox("focus", "Button", button_style(false, "hover"))
	t.set_color("font_color", "Button", FG)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_font_size("font_size", "Button", 16)

	t.set_color("font_color", "Label", FG)

	_theme = t
	return t


## Кнопка главного действия: та же тема, но залита бронзой.
static func make_primary(b: Button) -> void:
	b.add_theme_stylebox_override("normal", button_style(true, "normal"))
	b.add_theme_stylebox_override("hover", button_style(true, "hover"))
	b.add_theme_stylebox_override("pressed", button_style(true, "pressed"))
	b.add_theme_stylebox_override("focus", button_style(true, "hover"))
	b.add_theme_color_override("font_color", Color("#17130b"))
	b.add_theme_color_override("font_hover_color", Color("#17130b"))


# ------------------------------------------------------------------
# Мелкие сборщики
# ------------------------------------------------------------------

## Подпись с обводкой. Обводка обязательна для всего, что лежит поверх
## трёхмерной сцены: на светлом песке арены серый текст без неё исчезает.
static func label(text: String, size: int, color: Color,
		outline: int = 4) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		l.add_theme_constant_override("outline_size", outline)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Квадратная иконка заданного размера, окрашенная в цвет.
static func icon_rect(name: String, size: int, color: Color) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = icon(name)
	tr.custom_minimum_size = Vector2(size, size)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.modulate = color
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

class_name RoomGenerator
extends RefCounted

## Процедурная генерация комнат.
##
## Вынесено в отдельный класс без сцен и узлов: планировку можно прогонять
## тысячу раз в тесте и смотреть на распределение, не поднимая игру.
##
## Внутренние препятствия НЕ ставим намеренно. Зомби ходят к цели по прямой,
## без навигационной сетки, поэтому любая колонна посреди комнаты превращается
## в ловушку, где они топчутся до конца боя. Разнообразие даём контуром,
## размером, пропорциями, составом врагов и оформлением.

const THEMES := ["песчаная", "каменная", "багровая", "сумеречная"]
const CELL_SIZE := 2.0

## Габарит комнаты фиксирован: комнаты складываются в сетку этажа, центр
## комнаты считается как cell * (ROOM_WIDTH, ROOM_DEPTH). Числа обязаны быть
## нечётными в клетках, иначе у стороны нет центральной клетки и дверь некуда
## поставить.
const GRID_W := 13
const GRID_D := 11
const ROOM_WIDTH := float(GRID_W) * CELL_SIZE   ## 26.0 м
const ROOM_DEPTH := float(GRID_D) * CELL_SIZE   ## 22.0 м

const SHAPES := [
	"квадратная", "прямоугольная", "восьмиугольная", "ромбовидная",
	"Г-образная", "крестовая", "с вырезом"
]

## Цвет пола под тему - единственное, что тема меняет механически безопасно.
const THEME_FLOOR := {
	"песчаная": Color(0.74, 0.62, 0.43),
	"каменная": Color(0.52, 0.51, 0.48),
	"багровая": Color(0.56, 0.33, 0.30),
	"сумеречная": Color(0.36, 0.38, 0.47),
}


## Только геометрия и оформление. Баланс - количество врагов, их состав,
## лимиты - живёт в ThreatCurve: раньше планировщик и балансировщик сидели в
## одном файле, и это мешало тестировать обоих.
static func geometry(rng: RandomNumberGenerator) -> Dictionary:
	var shape: String = SHAPES[rng.randi_range(0, SHAPES.size() - 1)]
	var theme: String = THEMES[rng.randi_range(0, THEMES.size() - 1)]
	return {
		"shape": shape,
		"theme": theme,
		"grid_w": GRID_W,
		"grid_d": GRID_D,
		"width": ROOM_WIDTH,
		"depth": ROOM_DEPTH,
		"floor_color": THEME_FLOOR.get(theme, Color(0.74, 0.62, 0.43)),
	}


## Короткое описание для экрана перехода.
static func describe(cfg: Dictionary) -> String:
	return "Этаж %d · комната %s · %s" % [
		int(cfg.get("floor_number", 1)),
		str(cfg.get("shape", "прямоугольная")),
		str(cfg.get("theme", "каменная"))]


## Возвращает клетки пола комнаты. Стены строятся по открытым рёбрам этих
## клеток, поэтому одна и та же логика поддерживает прямоугольники и
## действительно разные контуры, а не только изменение размера арены.
static func cells_for(cfg: Dictionary) -> Array[Vector2i]:
	var w := int(cfg.get("grid_w", roundi(float(cfg.get("width", 24.0)) / CELL_SIZE)))
	var d := int(cfg.get("grid_d", roundi(float(cfg.get("depth", 24.0)) / CELL_SIZE)))
	var hx := maxi(1, w / 2)
	var hz := maxi(1, d / 2)
	var shape := str(cfg.get("shape", "прямоугольная"))
	var out: Array[Vector2i] = []

	for z in range(-hz, hz + 1):
		for x in range(-hx, hx + 1):
			var keep := true
			match shape:
				"восьмиугольная":
					keep = not (abs(x) >= hx - 1 and abs(z) >= hz - 1)
				"ромбовидная":
					keep = float(abs(x)) / float(hx) + float(abs(z)) / float(hz) <= 1.05
				"Г-образная":
					# Две широкие полосы с общей серединой дают проходимую Г-форму.
					keep = x >= 0 or z >= 0
				"крестовая":
					keep = abs(x) <= 1 or abs(z) <= 1
				"с вырезом":
					# Неровный контур с вырезанными углами, но с дверями
					# по центру каждой стороны.
					keep = not (x < -hx + 2 and z < -hz + 2)
				_:
					keep = true
			if keep:
				out.append(Vector2i(x, z))

	# Даже у необычного контура центральные клетки сторон должны существовать:
	# это гарантирует, что дверь можно состыковать с любой соседней комнатой.
	for edge in [Vector2i(0, -hz), Vector2i(0, hz), Vector2i(-hx, 0), Vector2i(hx, 0)]:
		if not out.has(edge):
			out.append(edge)
	return out

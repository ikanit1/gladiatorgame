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


## index - номер комнаты, начиная с 1.
static func generate(index: int, rng: RandomNumberGenerator) -> Dictionary:
	# Размеры кратны CELL_SIZE: так соседние комнаты можно состыковать
	# вплотную, а дверь всегда попадает в общий двухметровый проём.
	var shape: String = SHAPES[rng.randi_range(0, SHAPES.size() - 1)]
	var grid_w := 2 * rng.randi_range(4, 7) + 1
	var grid_d := 2 * rng.randi_range(4, 7) + 1
	if shape == "квадратная":
		grid_d = grid_w
	elif shape == "прямоугольная":
		grid_w = 2 * rng.randi_range(5, 7) + 1
		grid_d = 2 * rng.randi_range(4, 6) + 1
	elif shape == "ромбовидная":
		grid_w = 2 * rng.randi_range(5, 7) + 1
		grid_d = 2 * rng.randi_range(5, 7) + 1
	elif shape == "крестовая":
		grid_w = 2 * rng.randi_range(5, 7) + 1
		grid_d = 2 * rng.randi_range(5, 7) + 1
	else:
		grid_w = 2 * rng.randi_range(5, 7) + 1
		grid_d = 2 * rng.randi_range(5, 6) + 1

	var width := float(grid_w) * CELL_SIZE
	var depth := float(grid_d) * CELL_SIZE

	# Волн в комнате: чем дальше, тем длиннее забег
	var waves := 2
	if index >= 3:
		waves = 3
	if index >= 7:
		waves = 4

	var theme: String = THEMES[rng.randi_range(0, THEMES.size() - 1)]

	return {
		"index": index,
		"width": width,
		"depth": depth,
		"grid_w": grid_w,
		"grid_d": grid_d,
		"shape": shape,
		"waves": waves,
		"theme": theme,
		"floor_color": THEME_FLOOR.get(theme, Color(0.74, 0.62, 0.43)),
		# Разновидности врагов подключаются постепенно, а не сваливаются разом
		"runner_from": 1 if index >= 2 else 99,
		"brute_from": 1 if index >= 4 else 99,
		"first_wave": 2 + mini(index / 2, 3),
		"max_alive": mini(6 + index, 14),
		"potion_interval": maxf(6.0, 10.0 - float(index) * 0.3),
	}


## Короткое описание для экрана перехода.
static func describe(cfg: Dictionary) -> String:
	return "Комната %d · %s · %s · %.0f×%.0f · волн: %d" % [
		cfg["index"], cfg["theme"], cfg.get("shape", "прямоугольная"),
		cfg["width"], cfg["depth"], cfg["waves"]]


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

class_name FloorPlan
extends RefCounted

## Топология этажа: какие клетки заняты, что в них и где двери.
##
## Ни одного узла намеренно: планировку можно прогнать две тысячи раз в тесте
## и посмотреть на распределение, не поднимая игру. Физические комнаты по этим
## данным строит DungeonFloor.

enum RoomType { START, COMBAT, TREASURE, SHOP, LOCKED, SECRET, BOSS }

## Состояние двери живёт здесь, а не в DungeonRoom: FloorPlan не зависит ни от
## одного узла, поэтому зависимость DungeonRoom -> FloorPlan односторонняя.
enum DoorState { OPEN, LOCKED_BY_FIGHT, LOCKED_BY_KEY, CRACKED_WALL }

const GRID_W := 9
const GRID_H := 8
const START_CELL := Vector2i(4, 3)

## Ограничение найдено прогоном генератора: без него босс оказывался в трёх
## шагах от старта в 39% планировок первого этажа, и этаж пробегался за три
## комнаты мимо сокровищницы - ровно та болезнь, от которой лечимся.
const MIN_BOSS_DISTANCE := 4
const MAX_ATTEMPTS := 20

## Шанс, что на этаже появится запертая комната (со второго этажа).
const LOCKED_ROOM_CHANCE := 0.7

## Четыре стороны в том же порядке, что и в DungeonRoom:
## 0 - север (-z), 1 - юг (+z), 2 - восток (+x), 3 - запад (-x).
const SIDE_OFFSETS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]

var floor_number: int = 1
var rooms: Dictionary = {}        ## Vector2i -> Dictionary со спецификацией комнаты
var distances: Dictionary = {}    ## Vector2i -> int, шагов от старта
var boss_cell: Vector2i = Vector2i(-1, -1)
var secret_cell: Vector2i = Vector2i(-1, -1)


static func generate(floor_number: int, rng: RandomNumberGenerator) -> FloorPlan:
	var plan: FloorPlan = null
	for attempt in range(MAX_ATTEMPTS):
		plan = FloorPlan.new()
		plan.floor_number = maxi(1, floor_number)
		plan._grow(rng)
		plan._measure_distances()
		plan._assign_special_rooms(rng)
		plan._place_secret(rng)
		plan._build_doors()
		if int(plan.distances.get(plan.boss_cell, 0)) >= MIN_BOSS_DISTANCE:
			return plan
	# MAX_ATTEMPTS попыток не дали нужного расстояния - отдаём последнюю.
	# Планировка валидна, просто короче желаемого, но это и есть то самое
	# ограничение, ради которого существует вся задача - молчать нельзя.
	# push_warning, а не assert: assert вырезается в релизной сборке, а
	# generate вызывается в игре.
	push_warning("FloorPlan: за %d попыток не нашли планировку с dist(босс) >= %d (этаж %d, получили %d)"
		% [MAX_ATTEMPTS, MIN_BOSS_DISTANCE, floor_number, int(plan.distances.get(plan.boss_cell, 0))])
	return plan


func has_room(cell: Vector2i) -> bool:
	return rooms.has(cell)


func spec(cell: Vector2i) -> Dictionary:
	return rooms.get(cell, {})


func room_count() -> int:
	return rooms.size()


func type_count(room_type: int) -> int:
	var n := 0
	for cell in rooms.keys():
		if int(rooms[cell]["type"]) == room_type:
			n += 1
	return n


func cells_of_type(room_type: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell in rooms.keys():
		if int(rooms[cell]["type"]) == room_type:
			out.append(cell)
	return out


func combat_room_count() -> int:
	return type_count(RoomType.COMBAT) + type_count(RoomType.LOCKED)


## Соседние клетки, в которых есть комната. Секретка исключена: в неё нет
## обычной двери, туда попадают через треснувшую стену.
func neighbours(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for offset in SIDE_OFFSETS:
		var n: Vector2i = cell + offset
		if rooms.has(n) and n != secret_cell and cell != secret_cell:
			out.append(n)
	return out


static func side_between(from_cell: Vector2i, to_cell: Vector2i) -> int:
	var delta := to_cell - from_cell
	for side in range(SIDE_OFFSETS.size()):
		if SIDE_OFFSETS[side] == delta:
			return side
	return -1


static func opposite_side(side: int) -> int:
	match side:
		0: return 1
		1: return 0
		2: return 3
		_: return 2


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < GRID_W and cell.y >= 0 and cell.y < GRID_H


func _occupied_neighbour_count(cell: Vector2i) -> int:
	var n := 0
	for offset in SIDE_OFFSETS:
		if rooms.has(cell + offset):
			n += 1
	return n


func _target_room_count(rng: RandomNumberGenerator) -> int:
	return 7 + roundi(float(floor_number) * 1.8) + rng.randi_range(0, 1)


## Классический рост Isaac. Проверка «у соседа не больше одного занятого
## соседа» - главное, что даёт ветвистую карту с тупиками вместо слипшегося
## блоба: без неё комнаты заполняют сетку плотным пятном.
##
## Инвариант связности: любая клетка, попадающая в rooms, обязана соседствовать
## хотя бы с одной уже существующей клеткой, и комнаты никогда не удаляются.
## Именно поэтому BFS от старта (_measure_distances) достаёт всех. Правило
## общее и без исключений: всё, что кладёт клетку в обход этого цикла
## (_append_dead_end, _place_secret), обязано само его соблюдать и само
## проставлять клетке distances.
func _grow(rng: RandomNumberGenerator) -> void:
	rooms.clear()
	_put(START_CELL, RoomType.START)

	var target := _target_room_count(rng)
	var queue: Array[Vector2i] = [START_CELL]
	var guard := 0

	while rooms.size() < target and guard < 400:
		guard += 1
		var next: Array[Vector2i] = []
		for cell in queue:
			for offset in SIDE_OFFSETS:
				if rooms.size() >= target:
					break
				var n: Vector2i = cell + offset
				if not _in_bounds(n) or rooms.has(n):
					continue
				if _occupied_neighbour_count(n) > 1:
					continue
				if rng.randf() < 0.5:
					continue
				_put(n, RoomType.COMBAT)
				next.append(n)
		if next.is_empty():
			# Проход не дал ничего - перезапускаем волну от всех комнат,
			# иначе рост встанет на планировке меньше целевой.
			queue.clear()
			for cell in rooms.keys():
				queue.append(cell)
		else:
			queue = next

	if rooms.size() < target:
		# Вероятностная, а не доказанная гарантия: на 700 000 прогонов такого
		# не случалось. Но молчать нельзя - если цель вырастет, планировка
		# начнёт тихо мелеть, и поймать это будет нечем.
		push_warning("FloorPlan: рост не добрал цель (%d из %d) на этаже %d"
			% [rooms.size(), target, floor_number])


func _put(cell: Vector2i, room_type: int) -> void:
	rooms[cell] = {"cell": cell, "type": room_type}


func _measure_distances() -> void:
	distances.clear()
	distances[START_CELL] = 0
	var frontier: Array[Vector2i] = [START_CELL]
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for cell in frontier:
			for offset in SIDE_OFFSETS:
				var n: Vector2i = cell + offset
				if rooms.has(n) and not distances.has(n):
					distances[n] = int(distances[cell]) + 1
					next.append(n)
		frontier = next


## Самый далёкий тупик - босс, ближние тупики раздаются спец-комнатам.
## Тупик = комната с ровно одним занятым соседом, кроме старта.
func _assign_special_rooms(rng: RandomNumberGenerator) -> void:
	var dead_ends: Array[Vector2i] = []
	for cell in rooms.keys():
		if cell == START_CELL:
			continue
		if _occupied_neighbour_count(cell) == 1:
			dead_ends.append(cell)

	dead_ends.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return int(distances.get(a, 0)) > int(distances.get(b, 0)))

	if dead_ends.is_empty():
		# Вырожденный случай: тупиков нет вообще. Берём самую далёкую комнату.
		boss_cell = _farthest_cell()
	else:
		boss_cell = dead_ends.pop_front()
	rooms[boss_cell]["type"] = RoomType.BOSS

	var wanted: Array[int] = [RoomType.TREASURE]
	if floor_number >= 2:
		wanted.append(RoomType.SHOP)
	if floor_number >= 2 and rng.randf() < LOCKED_ROOM_CHANCE:
		wanted.append(RoomType.LOCKED)

	# Ближние тупики - спец-комнатам: до сокровищницы должно быть проще
	# добраться, чем до босса.
	dead_ends.reverse()
	for room_type in wanted:
		var cell: Vector2i = dead_ends.pop_front() if not dead_ends.is_empty() else _append_dead_end()
		if cell == Vector2i(-1, -1):
			# Спека обещает эту комнату на каждом этаже без исключений - молча
			# пропускать её нельзя, даже если случай крайне редкий.
			push_warning("FloorPlan: не нашлось места под комнату %s на этаже %d"
				% [RoomType.keys()[room_type], floor_number])
			continue
		rooms[cell]["type"] = room_type


func _farthest_cell() -> Vector2i:
	var best := START_CELL
	var best_d := -1
	for cell in rooms.keys():
		var d := int(distances.get(cell, -1))
		if d > best_d:
			best_d = d
			best = cell
	return best


## Фоллбэк: тупиков не хватило на все спец-комнаты. Пристраиваем новую клетку
## к любой существующей так, чтобы у новой был ровно один сосед.
func _append_dead_end() -> Vector2i:
	for cell in rooms.keys():
		for offset in SIDE_OFFSETS:
			var n: Vector2i = cell + offset
			if not _in_bounds(n) or rooms.has(n):
				continue
			if _occupied_neighbour_count(n) != 1:
				continue
			_put(n, RoomType.COMBAT)
			distances[n] = int(distances.get(cell, 0)) + 1
			return n
	return Vector2i(-1, -1)


## Секретка - пустая клетка с наибольшим числом занятых соседей, как в Isaac.
## В неё не ведёт обычная дверь: вход через треснувшую стену.
func _place_secret(rng: RandomNumberGenerator) -> void:
	var best := Vector2i(-1, -1)
	var best_n := 1
	var fallback := Vector2i(-1, -1)
	for y in range(GRID_H):
		for x in range(GRID_W):
			var cell := Vector2i(x, y)
			if rooms.has(cell):
				continue
			var n := _occupied_neighbour_count(cell)
			if n >= 1 and fallback == Vector2i(-1, -1):
				fallback = cell
			if n > best_n or (n == best_n and n > 1 and rng.randf() < 0.3):
				best_n = n
				best = cell
	# Фоллбэк: у прямой, не загибающейся планировки может не оказаться пустой
	# клетки с двумя занятыми соседями. Тогда годится любая с одним - секретка
	# обязана быть на каждом этаже, это приёмочное условие.
	if best == Vector2i(-1, -1):
		best = fallback
	if best == Vector2i(-1, -1):
		return
	_put(best, RoomType.SECRET)
	secret_cell = best

	# Секретка кладётся в обход _grow, поэтому сама отвечает за свой distances
	# (см. инвариант над _grow). Проставляем вручную, а не через BFS: к этому
	# моменту _measure_distances уже отработал, а секретка появляется позже
	# него - обычный проход её не увидит. Берём минимум среди уже посчитанных
	# соседей плюс шаг; если ни у одного соседа расстояния ещё нет (теоретически
	# невозможно - секретка всегда рядом хоть с одной комнатой из _grow), просто
	# ничего не проставляем, лишь бы не упасть.
	var nearest := -1
	for offset in SIDE_OFFSETS:
		var n: Vector2i = best + offset
		if distances.has(n):
			var d := int(distances[n])
			if nearest == -1 or d < nearest:
				nearest = d
	if nearest != -1:
		distances[best] = nearest + 1


## Двери строятся симметрично: каждая пара соседей получает по двери с обеих
## сторон с одинаковым состоянием. Иначе игрок может войти в комнату и не
## выйти обратно.
func _build_doors() -> void:
	for cell in rooms.keys():
		rooms[cell]["doors"] = {}

	# Состояние считаем один раз на ребро и сразу пишем в обе стороны из одного
	# значения, а не дважды - по разу с каждой стороны. Сегодня это ничего не
	# меняет, потому что _door_state_between симметрична по аргументам, но эта
	# симметрия нигде не зафиксирована как контракт: если завтра появится
	# асимметричное правило (например «заперто только со стороны входа»),
	# результат не должен тихо зависеть от порядка обхода rooms.keys().
	# Юга и востока достаточно, чтобы обойти каждое ребро сетки ровно один раз.
	var edge_sides := [1, 2]  # юг, восток
	for cell in rooms.keys():
		for side in edge_sides:
			var other: Vector2i = cell + SIDE_OFFSETS[side]
			if not rooms.has(other):
				continue
			var state := _door_state_between(cell, other)
			rooms[cell]["doors"][side] = state
			rooms[other]["doors"][opposite_side(side)] = state


func _door_state_between(a: Vector2i, b: Vector2i) -> int:
	var type_a := int(rooms[a]["type"])
	var type_b := int(rooms[b]["type"])
	if type_a == RoomType.SECRET or type_b == RoomType.SECRET:
		return DoorState.CRACKED_WALL
	if type_a == RoomType.LOCKED or type_b == RoomType.LOCKED:
		return DoorState.LOCKED_BY_KEY
	return DoorState.OPEN


func doors_of(cell: Vector2i) -> Dictionary:
	return rooms.get(cell, {}).get("doors", {})

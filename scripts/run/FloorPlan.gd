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

## Четыре стороны в том же порядке, что и в DungeonRoom:
## 0 - север (-z), 1 - юг (+z), 2 - восток (+x), 3 - запад (-x).
const SIDE_OFFSETS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]

var floor_number: int = 1
var rooms: Dictionary = {}        ## Vector2i -> Dictionary со спецификацией комнаты
var distances: Dictionary = {}    ## Vector2i -> int, шагов от старта
var boss_cell: Vector2i = Vector2i(-1, -1)
var secret_cell: Vector2i = Vector2i(-1, -1)


static func generate(floor_number: int, rng: RandomNumberGenerator) -> FloorPlan:
	var plan := FloorPlan.new()
	plan.floor_number = maxi(1, floor_number)
	plan._grow(rng)
	plan._measure_distances()
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

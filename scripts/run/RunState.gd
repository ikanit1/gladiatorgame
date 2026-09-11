class_name RunState
extends RefCounted

## Состояние забега: кошелёк, взятые апгрейды, карта посещённого.
##
## Отдельно от Arena намеренно: Arena это окружение обучения, и рогалик-
## экономика в ней стала бы миной под обучением.

signal changed()

var floor_number: int = 1
var coins: int = 0
var keys: int = 1
var bombs: int = 1
var taken_upgrades: Array[String] = []

var visited: Dictionary = {}   ## Vector2i -> true
var cleared: Dictionary = {}   ## Vector2i -> true


func add_coins(amount: int) -> void:
	coins = maxi(0, coins + amount)
	changed.emit()


func spend_coins(amount: int) -> bool:
	if amount > coins:
		return false
	coins -= amount
	changed.emit()
	return true


func add_keys(amount: int) -> void:
	keys = maxi(0, keys + amount)
	changed.emit()


func use_key() -> bool:
	if keys <= 0:
		return false
	keys -= 1
	changed.emit()
	return true


func add_bombs(amount: int) -> void:
	bombs = maxi(0, bombs + amount)
	changed.emit()


func use_bomb() -> bool:
	if bombs <= 0:
		return false
	bombs -= 1
	changed.emit()
	return true


func mark_visited(cell: Vector2i) -> void:
	visited[cell] = true
	changed.emit()


func is_visited(cell: Vector2i) -> bool:
	return visited.has(cell)


func mark_cleared(cell: Vector2i) -> void:
	cleared[cell] = true
	changed.emit()


func is_cleared(cell: Vector2i) -> bool:
	return cleared.has(cell)


## Сколько боевых комнат этажа зачищено. Это числитель глубины в ThreatCurve,
## поэтому считаем только бой: сокровищница и лавка в прогресс не идут.
func cleared_combat_rooms(plan: FloorPlan) -> int:
	if plan == null:
		return 0
	var n := 0
	for cell in cleared.keys():
		if not plan.has_room(cell):
			continue
		var room_type := int(plan.spec(cell)["type"])
		if room_type == FloorPlan.RoomType.COMBAT or room_type == FloorPlan.RoomType.LOCKED:
			n += 1
	return n


## Спуск на следующий этаж. Кошелёк и апгрейды переносятся, карта - нет.
func next_floor() -> void:
	floor_number += 1
	visited.clear()
	cleared.clear()
	changed.emit()

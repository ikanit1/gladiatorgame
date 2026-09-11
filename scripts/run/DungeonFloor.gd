class_name DungeonFloor
extends Node3D

## Физические комнаты этажа.
##
## Комнаты строятся при первом входе, а не все сразу: этаж на девятнадцать
## комнат с перекрытиями и лампами - это десятки тысяч узлов, и строить их
## заранее незачем, половину игрок не посетит.

signal room_built(cell: Vector2i, room: DungeonRoom)

var plan: FloorPlan = null
var current_cell: Vector2i = Vector2i(-1, -1)
var visuals_enabled: bool = true

var _rooms: Dictionary = {}   ## Vector2i -> DungeonRoom
var _rng := RandomNumberGenerator.new()


func setup(new_plan: FloorPlan, show_visuals: bool) -> void:
	plan = new_plan
	visuals_enabled = show_visuals
	_rng.randomize()
	_rooms.clear()
	current_cell = Vector2i(-1, -1)


## Центр комнаты в локальных координатах этажа. Шаг сетки равен габариту
## комнаты: соседние комнаты стоят стена к стене, коридоров нет.
func world_center_of(cell: Vector2i) -> Vector3:
	return Vector3(
		float(cell.x) * RoomGenerator.ROOM_WIDTH,
		0.0,
		float(cell.y) * RoomGenerator.ROOM_DEPTH)


func room_at(cell: Vector2i) -> DungeonRoom:
	if _rooms.has(cell):
		return _rooms[cell]
	if plan == null or not plan.has_room(cell):
		return null

	var spec := plan.spec(cell)
	var cfg := RoomGenerator.geometry(_rng)
	cfg["floor_number"] = plan.floor_number
	cfg["type"] = spec["type"]
	cfg["cell"] = cell

	var room := DungeonRoom.new()
	room.name = "Room_%d_%d" % [cell.x, cell.y]
	add_child(room)
	room.setup(cfg, world_center_of(cell), plan.doors_of(cell), visuals_enabled)
	_rooms[cell] = room
	room_built.emit(cell, room)
	return room


func built_room(cell: Vector2i) -> DungeonRoom:
	return _rooms.get(cell)


## Помечает клетку текущей и строит её, если ещё не построена. Соседей тоже
## строим заранее: иначе при переходе игрок на кадр проваливается в пустоту,
## пока строится следующая комната.
func enter_cell(cell: Vector2i) -> DungeonRoom:
	var room := room_at(cell)
	if room == null:
		return null
	current_cell = cell
	for side in plan.doors_of(cell).keys():
		room_at(cell + FloorPlan.SIDE_OFFSETS[side])
	return room


func current_room() -> DungeonRoom:
	return built_room(current_cell)

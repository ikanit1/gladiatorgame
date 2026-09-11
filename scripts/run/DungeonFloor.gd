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
	if plan != null:
		# Повторный setup() уже построенного этажа оставил бы дочерние
		# DungeonRoom висеть в дереве осиротевшими: _rooms.clear() ниже
		# забыл бы про них, а сами узлы никуда не делись бы. DungeonFloor
		# сегодня создаётся заново на каждый этаж (GameScreen так и делает),
		# но API это не запрещает - защищаемся зеркально DungeonRoom._build.
		# push_error, а не assert: assert вырезается в релизной сборке.
		push_error("DungeonFloor: повторный setup() на уже настроенном этаже - отменяю")
		return
	plan = new_plan
	visuals_enabled = show_visuals
	_rng.randomize()
	# _rooms.clear() не нужен: до этой строки setup() гарантированно ни разу
	# не выполнялся (см. проверку выше), а словарь и так пуст при создании.
	current_cell = Vector2i(-1, -1)


## Центр комнаты в координатах пространства DungeonFloor - НЕ глобальных.
## Шаг сетки равен габариту комнаты: соседние комнаты стоят стена к стене,
## коридоров нет.
##
## Локальные, а не глобальные координаты - осознанный выбор: результат идёт
## прямиком в DungeonRoom.setup(center), где становится position, а position
## в Godot всегда относителен родителя (самого этажа). Если понадобятся
## глобальные координаты (например, будущей миникарте) - не путай с этой
## функцией, глобальные даёт to_global() на самой комнате, как в
## DungeonRoom.door_position().
func local_center_of(cell: Vector2i) -> Vector3:
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
	room.setup(cfg, local_center_of(cell), plan.doors_of(cell), visuals_enabled)
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
		# Среди дверей попадается и CRACKED_WALL - сосед за ней секретная
		# комната, и её тоже строим здесь, не дожидаясь подрыва. Во втором
		# плане стену подрывают бомбой в любой момент пребывания в этой
		# комнате, а не только в кадре входа - построить секретку по факту
		# взрыва уже поздно. Это не выдаёт секретку: снаружи CRACKED_WALL
		# неотличима от обычной стены (DungeonRoom ставит на её месте
		# стеновой сегмент, а не ворота - см. _build_secret_wall_panel), а
		# коллизию проёма даёт блокиратор. Лидар напарника - это лучи: они
		# останавливаются на первом коллайдере и не видят, что за ним.
		room_at(cell + FloorPlan.SIDE_OFFSETS[side])
	return room


func current_room() -> DungeonRoom:
	return built_room(current_cell)

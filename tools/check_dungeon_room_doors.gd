extends SceneTree

## Поведенческая проверка дверей DungeonRoom.
##
## План задачи 6 проверяет только то, что файл парсится (--import без ошибок).
## До задачи 7 (DungeonFloor) это единственная проверка того, что блокиратор и
## панель двери действительно появляются, включаются/выключаются в обе стороны
## и что стены рядом с дверью и правда не строятся.

const SIDE_NAMES := ["север", "юг", "восток", "запад"]

## Фиксированный прямоугольный контур 13x11: "квадратная" в cells_for() не
## попадает ни в один особый case и даёт полный прямоугольник, поэтому
## _min_cell/_max_cell предсказуемы и не зависят от RNG.
const ROOM_CFG := {"shape": "квадратная", "grid_w": 13, "grid_d": 11}


func _initialize() -> void:
	# _init() у SceneTree слишком рано для await process_frame (нужен для
	## set_deferred("disabled", ...) у блокиратора) - откладываем на кадр так
	# же, как это делает check_fortress_assets.gd.
	call_deferred("run_checks")


func run_checks() -> void:
	var r := TestReport.new("DungeonRoom doors")

	# Каждая _check_* - корутина (внутри await process_frame). Без await здесь
	# run_checks не дождётся ни одной из них: вызов корутины без await лишь
	# запускает её до первого await и тут же отдаёт управление дальше, а
	# r.finish() позвал бы quit() раньше, чем резюмировались отложенные
	# продолжения - искомые r.check(...) внутри них просто не успели бы
	# выполниться, и итог выглядел бы как "проверок: 0, упало: 0".
	await _check_all_four_doors(r)
	await _check_toggle_both_ways(r)
	await _check_missing_door_is_noop(r)
	await _check_open_sides(r)
	await _check_door_positions_symmetric(r)
	await _check_no_doors_room(r)
	await _check_wall_counts(r)

	r.finish(self)


## Комната с дверями на все четыре стороны в разных состояниях: у каждой
## стороны должен появиться блокиратор и (при visuals_enabled=true) панель,
## и оба должны стоять в состоянии, соответствующем DoorState.
func _check_all_four_doors(r: TestReport) -> void:
	var doors := {
		0: FloorPlan.DoorState.OPEN,
		1: FloorPlan.DoorState.LOCKED_BY_FIGHT,
		2: FloorPlan.DoorState.LOCKED_BY_KEY,
		3: FloorPlan.DoorState.CRACKED_WALL,
	}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, true)
	await process_frame

	for side in doors.keys():
		var blocker := room.get_node_or_null("WallCollision/DoorBlocker_%d" % side)
		var panel := room.get_node_or_null("ClosedDoor_%d" % side)
		r.check(blocker != null, "блокиратор существует для стороны %s" % SIDE_NAMES[side])
		r.check(panel != null, "панель существует для стороны %s (visuals_enabled=true)" % SIDE_NAMES[side])

		var should_be_open: bool = int(doors[side]) == FloorPlan.DoorState.OPEN
		if blocker != null:
			r.eq(blocker.disabled, should_be_open,
				"блокиратор стороны %s disabled соответствует состоянию" % SIDE_NAMES[side])
		if panel != null:
			r.eq(panel.visible, not should_be_open,
				"панель стороны %s visible соответствует состоянию" % SIDE_NAMES[side])

	room.free()
	await process_frame


## set_door_state обязана переключать блокиратор и панель в обе стороны, и
## после await process_frame (set_deferred) отражать актуальное состояние.
func _check_toggle_both_ways(r: TestReport) -> void:
	var doors := {0: FloorPlan.DoorState.LOCKED_BY_FIGHT}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, true)
	await process_frame

	var blocker: CollisionShape3D = room.get_node("WallCollision/DoorBlocker_0")
	var panel: MeshInstance3D = room.get_node("ClosedDoor_0")
	r.check(not blocker.disabled, "изначально заперто боем -> блокиратор включён")
	r.check(panel.visible, "изначально заперто боем -> панель видима")

	room.set_door_state(0, FloorPlan.DoorState.OPEN)
	await process_frame
	r.check(blocker.disabled, "после открытия блокиратор выключен")
	r.check(not panel.visible, "после открытия панель скрыта")
	r.eq(room.door_state(0), FloorPlan.DoorState.OPEN, "door_state отражает открытое состояние")

	room.set_door_state(0, FloorPlan.DoorState.LOCKED_BY_KEY)
	await process_frame
	r.check(not blocker.disabled, "после запирания на ключ блокиратор снова включён")
	r.check(panel.visible, "после запирания на ключ панель снова видима")
	r.eq(room.door_state(0), FloorPlan.DoorState.LOCKED_BY_KEY, "door_state отражает запертое на ключ состояние")

	room.free()
	await process_frame


## set_door_state для стороны, где двери нет, не создаёт узлов и не падает.
func _check_missing_door_is_noop(r: TestReport) -> void:
	var doors := {0: FloorPlan.DoorState.OPEN}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, true)
	await process_frame

	room.set_door_state(2, FloorPlan.DoorState.OPEN)
	await process_frame

	r.check(room.get_node_or_null("WallCollision/DoorBlocker_2") == null,
		"set_door_state на стороне без двери не создаёт блокиратор")
	r.check(room.get_node_or_null("ClosedDoor_2") == null,
		"set_door_state на стороне без двери не создаёт панель")
	r.eq(room.door_state(2), FloorPlan.DoorState.LOCKED_BY_FIGHT,
		"door_state для отсутствующей двери возвращает значение по умолчанию")
	# Дверь, которая реально есть, не должна была пострадать от вызова выше.
	var blocker0: CollisionShape3D = room.get_node("WallCollision/DoorBlocker_0")
	r.check(blocker0.disabled, "существующая дверь стороны 0 не пострадала от вызова на другой стороне")

	room.free()
	await process_frame


## open_sides() обязана вернуть ровно стороны в состоянии OPEN, не больше и
## не меньше.
func _check_open_sides(r: TestReport) -> void:
	var doors := {
		0: FloorPlan.DoorState.OPEN,
		1: FloorPlan.DoorState.LOCKED_BY_FIGHT,
		2: FloorPlan.DoorState.OPEN,
		3: FloorPlan.DoorState.LOCKED_BY_KEY,
	}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, false)
	await process_frame

	var open: Array[int] = room.open_sides()
	open.sort()
	r.eq(open, [0, 2], "open_sides вернула ровно стороны в состоянии OPEN")

	room.free()
	await process_frame


## door_position(side) для противоположных сторон должна быть симметрична
## относительно центра комнаты, а inside_door_position(side) - лежать ближе
## к центру, чем door_position(side).
func _check_door_positions_symmetric(r: TestReport) -> void:
	var doors := {
		0: FloorPlan.DoorState.OPEN,
		1: FloorPlan.DoorState.OPEN,
		2: FloorPlan.DoorState.OPEN,
		3: FloorPlan.DoorState.OPEN,
	}
	var center := Vector3(5.0, 0.0, -3.0)
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, center, doors, false)
	await process_frame

	# Сравниваем только по горизонтали (x, z): door_position всегда поднимает
	# точку на Vector3.UP * 0.15 одинаково для обеих сторон пары, так что по
	# высоте среднее всегда смещено от центра ровно на эту константу - это не
	# нарушение симметрии, а не то, что здесь проверяется.
	for pair in [[0, 1], [2, 3]]:
		var a: int = pair[0]
		var b: int = pair[1]
		var pa := room.door_position(a)
		var pb := room.door_position(b)
		var mid := (pa + pb) * 0.5
		var mid_flat := Vector2(mid.x, mid.z)
		var center_flat := Vector2(center.x, center.z)
		r.in_range(mid_flat.distance_to(center_flat), 0.0, 0.05,
			"двери %s/%s симметричны относительно центра комнаты" % [SIDE_NAMES[a], SIDE_NAMES[b]])

	for side in doors.keys():
		var outer := room.door_position(side)
		var inner := room.inside_door_position(side)
		r.check(center.distance_to(inner) < center.distance_to(outer),
			"inside_door_position стороны %s ближе к центру, чем door_position" % SIDE_NAMES[side])

	room.free()
	await process_frame


## Комната без дверей не создаёт ни одного блокиратора.
func _check_no_doors_room(r: TestReport) -> void:
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, {}, false)
	await process_frame

	var wall_collision: Node = room.get_node("WallCollision")
	var blockers := 0
	for child in wall_collision.get_children():
		if str(child.name).begins_with("DoorBlocker_"):
			blockers += 1
	r.eq(blockers, 0, "комната без дверей не создаёт блокираторов")

	room.free()
	await process_frame


## Стены: дверь на стороне вынимает ровно одну стеновую форму (центральную
## клетку той стороны) и добавляет ровно один блокиратор. Считаем отдельно
## "стеновые" CollisionShape3D (без двери) и блокираторы, чтобы разница в
## одну штуку не потерялась в общей сумме - у одной комнаты стен на одну
## меньше, а блокираторов на одну больше, итоговое число форм совпадает.
func _check_wall_counts(r: TestReport) -> void:
	var closed_room := DungeonRoom.new()
	root.add_child(closed_room)
	closed_room.setup(ROOM_CFG, Vector3.ZERO, {}, false)
	await process_frame

	var one_door_room := DungeonRoom.new()
	root.add_child(one_door_room)
	one_door_room.setup(ROOM_CFG, Vector3.ZERO, {0: FloorPlan.DoorState.LOCKED_BY_FIGHT}, false)
	await process_frame

	var closed_counts := _count_wall_shapes(closed_room)
	var one_door_counts := _count_wall_shapes(one_door_room)

	r.eq(one_door_counts["wall"], closed_counts["wall"] - 1,
		"дверь на стороне убирает ровно одну стеновую форму")
	r.eq(one_door_counts["blocker"], closed_counts["blocker"] + 1,
		"дверь на стороне добавляет ровно одну форму-блокиратор")
	r.eq(closed_counts["blocker"], 0, "у закрытой комнаты блокираторов нет")

	closed_room.free()
	one_door_room.free()
	await process_frame


func _count_wall_shapes(room: DungeonRoom) -> Dictionary:
	var wall_collision: Node = room.get_node("WallCollision")
	var wall := 0
	var blocker := 0
	for child in wall_collision.get_children():
		if not (child is CollisionShape3D):
			continue
		if str(child.name).begins_with("DoorBlocker_"):
			blocker += 1
		else:
			wall += 1
	return {"wall": wall, "blocker": blocker}

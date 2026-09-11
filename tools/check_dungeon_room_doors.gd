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

	# Проверки по находкам ревью задачи 6 (правки 1-4 DungeonRoom.gd).
	await _check_secret_wall_indistinguishable(r)
	await _check_secret_wall_opens(r)
	await _check_secret_wall_vs_locked_door(r)
	await _check_has_door(r)
	await _check_frame_recolors_on_state_change(r)
	await _check_repeated_setup_is_guarded(r)

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


## Имена узлов, которые wall_detail() вешает на обычный сегмент стены
## (FortressDecor.gd). Обычный визуальный меш стены/панели своего имени не
## получает (движок сам называет его "MeshInstance3D..."), поэтому фильтр по
## этим именам отделяет декоративные накладки от самого стенового фасада.
const _WALL_DETAIL_NAMES := ["WallCornice", "WallFooting", "WallPillar"]


## Первый "голый" стеновой меш под WallVisual на стороне side (без учёта
## накладок wall_detail): у стен севера/юга он растянут по x и сплюснут по z,
## у востока/запада - наоборот. Формула размера в _add_wall не зависит от
## конкретной клетки, только от стороны, так что для сравнения размеров
## годится любой сегмент этой стороны, а не обязательно сосед двери.
func _find_plain_wall_mesh(wall_visual: Node, side: int) -> BoxMesh:
	var along_x := side < 2  # север/юг: широкий по x, сплюснут по z
	for child in wall_visual.get_children():
		if not (child is MeshInstance3D):
			continue
		if str(child.name) in _WALL_DETAIL_NAMES:
			continue
		var mesh: Mesh = (child as MeshInstance3D).mesh
		if not (mesh is BoxMesh):
			continue
		var box := mesh as BoxMesh
		if (box.size.x > box.size.z) == along_x:
			return box
	return null


## Правка 1 ревью задачи 6: секретная стена (CRACKED_WALL) обязана быть
## неотличима от соседнего сегмента стены снаружи - без рамки, без жаровен и
## баннера входа, без кованых ворот, и с тем же по размеру мешем, что и у
## обычной стены той же стороны.
##
## Как поймать регресс: временно верни в _build() безусловный вызов
## _add_door_frame для всех состояний (включая CRACKED_WALL) - эта проверка
## должна упасть на "нет жаровен/баннера у CRACKED_WALL". Проверено вручную
## при написании правки, ниже оставлен только итоговый вариант.
func _check_secret_wall_indistinguishable(r: TestReport) -> void:
	var doors := {0: FloorPlan.DoorState.CRACKED_WALL}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, true)
	await process_frame

	var wall_visual: Node = room.get_node("WallVisual")
	var has_entrance_prop := false
	for child in wall_visual.get_children():
		var n := str(child.name)
		if n.begins_with("GateBrazier") or n.begins_with("BrazierFlame") \
				or n.begins_with("GateBanner") or n.begins_with("BannerRod") \
				or n.begins_with("BronzeDiamond"):
			has_entrance_prop = true
	r.check(not has_entrance_prop,
		"CRACKED_WALL: под WallVisual нет жаровен/баннера входа (entrance_details не звали)")

	var panel := room.get_node_or_null("ClosedDoor_0")
	r.check(panel != null, "CRACKED_WALL: панель ClosedDoor_0 существует")
	if panel == null:
		room.free()
		await process_frame
		return

	r.check(panel.visible, "CRACKED_WALL: панель видима до подрыва стены")
	r.check(panel.get_node_or_null("IronPortcullis") == null,
		"CRACKED_WALL: в панели нет кованых ворот IronPortcullis")

	var secret_mesh: BoxMesh = (panel as MeshInstance3D).mesh as BoxMesh
	r.check(secret_mesh != null, "CRACKED_WALL: панель использует BoxMesh, как обычная стена")

	var reference_mesh := _find_plain_wall_mesh(wall_visual, 0)
	r.check(reference_mesh != null, "нашли обычный стеновой сегмент стороны 0 для сравнения")
	if secret_mesh != null and reference_mesh != null:
		r.eq(secret_mesh.size, reference_mesh.size,
			"панель CRACKED_WALL по размеру меша совпадает с обычным сегментом стены")

	room.free()
	await process_frame


## Правка 1: подрыв стены - один вызов set_door_state(side, OPEN) должен
## открывать CRACKED_WALL точно так же, как обычную дверь: панель прячется,
## блокиратор проёма выключается (после await process_frame, т.к. отключение
## идёт через set_deferred).
func _check_secret_wall_opens(r: TestReport) -> void:
	var doors := {0: FloorPlan.DoorState.CRACKED_WALL}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, true)
	await process_frame

	var blocker: CollisionShape3D = room.get_node("WallCollision/DoorBlocker_0")
	var panel: MeshInstance3D = room.get_node("ClosedDoor_0")
	r.check(not blocker.disabled, "CRACKED_WALL: изначально коллизия стены на месте")
	r.check(panel.visible, "CRACKED_WALL: изначально панель-стена видима")

	room.set_door_state(0, FloorPlan.DoorState.OPEN)
	await process_frame
	r.check(blocker.disabled, "CRACKED_WALL: после подрыва блокиратор выключен")
	r.check(not panel.visible, "CRACKED_WALL: после подрыва панель-стена скрыта")
	r.eq(room.door_state(0), FloorPlan.DoorState.OPEN,
		"CRACKED_WALL: door_state отражает открытое состояние после подрыва")

	room.free()
	await process_frame


## Правка 1, регресс в обе стороны: одна сторона CRACKED_WALL, другая
## LOCKED_BY_KEY. У запертой на ключ двери убранство входа (жаровни) и ворота
## должны остаться на месте, у секретной - не появиться вовсе. Без этой связки
## проверка выше могла бы случайно пройти из-за поломки, которая просто убрала
## бы decor у ВСЕХ дверей, а не только у CRACKED_WALL.
func _check_secret_wall_vs_locked_door(r: TestReport) -> void:
	var doors := {
		0: FloorPlan.DoorState.CRACKED_WALL,
		1: FloorPlan.DoorState.LOCKED_BY_KEY,
	}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, true)
	await process_frame

	var wall_visual: Node = room.get_node("WallVisual")
	# Внимание: FortressDecor.entrance_details() зовёт root.add_child(prop) без
	# force_readable_name, а обе жаровни одной двери называются одинаково
	# ("GateBrazier") - Godot оставляет читаемое имя только первой, вторая
	# молча получает анонимное "@Node3D@N" (это существующее поведение
	# FortressDecor.gd, не связанное с этой правкой). Поэтому считаем "жаровня
	# входа была добавлена хотя бы раз", а не ровно дважды - иначе проверка
	# была бы завязана на эту не относящуюся к делу особенность именования.
	var braziers := 0
	for child in wall_visual.get_children():
		if str(child.name).begins_with("GateBrazier"):
			braziers += 1
	r.check(braziers >= 1, "у двери LOCKED_BY_KEY жаровня входа осталась")

	var secret_panel := room.get_node("ClosedDoor_0")
	var locked_panel := room.get_node("ClosedDoor_1")
	r.check(secret_panel.get_node_or_null("IronPortcullis") == null,
		"у CRACKED_WALL кованых ворот нет")
	r.check(locked_panel.get_node_or_null("IronPortcullis") != null,
		"у LOCKED_BY_KEY кованые ворота остались")

	room.free()
	await process_frame


## Правка 2: has_door(side) обязана быть true ровно для сторон из словаря
## doors и false для всех остальных, включая случай, когда единственная дверь
## комнаты - CRACKED_WALL.
func _check_has_door(r: TestReport) -> void:
	var doors := {
		0: FloorPlan.DoorState.OPEN,
		2: FloorPlan.DoorState.CRACKED_WALL,
	}
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(ROOM_CFG, Vector3.ZERO, doors, false)
	await process_frame

	for side in range(4):
		r.eq(room.has_door(side), doors.has(side),
			"has_door(%s) соответствует наличию двери в словаре" % SIDE_NAMES[side])

	room.free()
	await process_frame


## Правка 3: после set_door_state рамка обязана перекраситься так, будто дверь
## сразу была построена в новом состоянии. Сравниваем с эталонами - дверьми,
## построенными сразу закрытой и сразу открытой, - а не с зашитыми цветами:
## так проверка переживёт правку палитры.
func _check_frame_recolors_on_state_change(r: TestReport) -> void:
	var ref_open := DungeonRoom.new()
	root.add_child(ref_open)
	ref_open.setup(ROOM_CFG, Vector3.ZERO, {0: FloorPlan.DoorState.OPEN}, true)

	var ref_closed := DungeonRoom.new()
	root.add_child(ref_closed)
	ref_closed.setup(ROOM_CFG, Vector3.ZERO, {0: FloorPlan.DoorState.LOCKED_BY_FIGHT}, true)

	var dynamic_room := DungeonRoom.new()
	root.add_child(dynamic_room)
	dynamic_room.setup(ROOM_CFG, Vector3.ZERO, {0: FloorPlan.DoorState.LOCKED_BY_FIGHT}, true)
	await process_frame

	var open_mat: StandardMaterial3D = ref_open._frame_materials.get(0)
	var closed_mat: StandardMaterial3D = ref_closed._frame_materials.get(0)
	var dyn_mat: StandardMaterial3D = dynamic_room._frame_materials.get(0)
	r.check(open_mat != null and closed_mat != null and dyn_mat != null,
		"у всех трёх комнат нашёлся материал рамки стороны 0")

	if open_mat != null and closed_mat != null and dyn_mat != null:
		r.check(open_mat.albedo_color != closed_mat.albedo_color,
			"эталоны открыто/заперто выглядят по-разному (проверка не выродилась)")
		r.eq(dyn_mat.albedo_color, closed_mat.albedo_color,
			"построенная запертой дверь изначально выглядит как эталон «заперто»")

		dynamic_room.set_door_state(0, FloorPlan.DoorState.OPEN)
		await process_frame
		r.eq(dyn_mat.albedo_color, open_mat.albedo_color,
			"после открытия цвет рамки стал как у эталона «открыто»")
		r.eq(dyn_mat.emission_enabled, open_mat.emission_enabled,
			"после открытия свечение рамки стало как у эталона «открыто»")

		dynamic_room.set_door_state(0, FloorPlan.DoorState.LOCKED_BY_FIGHT)
		await process_frame
		r.eq(dyn_mat.albedo_color, closed_mat.albedo_color,
			"после повторного запирания рамка снова выглядит как эталон «заперто»")
		r.eq(dyn_mat.emission_enabled, closed_mat.emission_enabled,
			"после повторного запирания свечение рамки снова как у эталона «заперто»")

	ref_open.free()
	ref_closed.free()
	dynamic_room.free()
	await process_frame


## Правка 4: повторный setup() на уже построенной комнате не должен удваивать
## коллизионные формы в WallCollision. push_error в выводе при этом ожидаем -
## это и есть защита, отменяющая повторную постройку, а не поломка.
func _check_repeated_setup_is_guarded(r: TestReport) -> void:
	var room := DungeonRoom.new()
	root.add_child(room)
	var doors := {0: FloorPlan.DoorState.OPEN}
	room.setup(ROOM_CFG, Vector3.ZERO, doors, false)
	await process_frame

	var wall_collision: Node = room.get_node("WallCollision")
	var before := wall_collision.get_child_count()

	room.setup(ROOM_CFG, Vector3.ZERO, doors, false)
	await process_frame

	var after := wall_collision.get_child_count()
	r.eq(after, before, "повторный setup() не удваивает формы в WallCollision")

	room.free()
	await process_frame

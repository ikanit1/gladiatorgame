class_name DungeonRoom
extends Node3D

## Физическая комната данжа.
##
## Пол состоит из клеток, а стены - из открытых рёбер этих клеток. Благодаря
## этому контур комнаты может быть квадратным, ромбовидным, Г-образным или
## крестовым, при этом соседние комнаты всё равно стыкуются по одной двери.

const CELL_SIZE := RoomGenerator.CELL_SIZE
const WALL_THICKNESS := 0.6
const WALL_HEIGHT := 3.0
const CEILING_THICKNESS := 0.3
## Шаг светильников под перекрытием, в клетках (клетка - 2 метра).
const LAMP_STEP := 4
const LAMP_ENERGY := 3.2
const LAMP_RANGE := 12.0
const DOOR_WIDTH := CELL_SIZE

var config: Dictionary = {}
var visuals_enabled: bool = true

## side -> FloorPlan.DoorState. Состояние двери живёт в FloorPlan: он не
## зависит ни от одного узла, поэтому зависимость односторонняя.
var doors: Dictionary = {}

var _cells: Dictionary = {}
var _min_cell := Vector2i.ZERO
var _max_cell := Vector2i.ZERO
var _blockers: Dictionary = {}   ## side -> CollisionShape3D
var _panels: Dictionary = {}     ## side -> MeshInstance3D
## side -> StandardMaterial3D рамки двери. Записи нет для CRACKED_WALL - у
## секретной стены рамки нет вообще (см. _build). set_door_state пересчитывает
## цвет через этот же материал, а не создаёт новый, поэтому дверь и рамка не
## могут разъехаться по состоянию.
var _frame_materials: Dictionary = {}


func setup(new_config: Dictionary, center: Vector3, new_doors: Dictionary,
		show_visuals: bool) -> void:
	config = new_config
	position = center
	doors = new_doors.duplicate()
	visuals_enabled = show_visuals
	_build()


func _build() -> void:
	if not _cells.is_empty():
		# Повторный setup() построил бы второе поддерево (FloorCollision,
		# WallCollision и так далее) поверх первого, а словари _blockers/
		# _panels/_cells/_frame_materials просто перезаписались бы новыми
		# значениями - старые узлы остались бы висеть в дереве осиротевшими,
		# их никто не находит и не освобождает. push_error, а не assert:
		# assert вырезается в релизной сборке, а setup() зовёт игровой код
		# (кеш комнат из задачи 7).
		push_error("DungeonRoom: повторный setup() на уже построенной комнате - отменяю, чтобы не задвоить поддерево")
		return
	var cells: Array[Vector2i] = RoomGenerator.cells_for(config)
	if cells.is_empty():
		return
	_min_cell = cells[0]
	_max_cell = cells[0]
	for cell in cells:
		_cells[cell] = true
		_min_cell.x = mini(_min_cell.x, cell.x)
		_min_cell.y = mini(_min_cell.y, cell.y)
		_max_cell.x = maxi(_max_cell.x, cell.x)
		_max_cell.y = maxi(_max_cell.y, cell.y)

	var floor_body := StaticBody3D.new()
	floor_body.name = "FloorCollision"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	add_child(floor_body)

	var wall_body := StaticBody3D.new()
	wall_body.name = "WallCollision"
	wall_body.collision_layer = 1
	wall_body.collision_mask = 0
	add_child(wall_body)

	var floor_visual: Node3D = null
	var wall_visual: Node3D = null
	var floor_material := _material(config.get("floor_color", Color(0.55, 0.45, 0.3)))
	var wall_material := _material(Color(0.26, 0.27, 0.29))
	wall_material.roughness = 0.82
	if visuals_enabled:
		floor_material = load("res://materials/m_fortress_floor.tres").duplicate() as StandardMaterial3D
		var theme_color: Color = config.get("floor_color", Color(0.55, 0.45, 0.3))
		floor_material.albedo_color = Color.WHITE.lerp(theme_color, 0.28)
		wall_material = load("res://materials/m_fortress_wall.tres") as StandardMaterial3D
		floor_visual = Node3D.new()
		floor_visual.name = "FloorVisual"
		add_child(floor_visual)
		wall_visual = Node3D.new()
		wall_visual.name = "WallVisual"
		add_child(wall_visual)

	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(CELL_SIZE, 0.06, CELL_SIZE)
	floor_mesh.material = floor_material
	for cell in cells:
		var local := _cell_position(cell)
		var floor_shape := CollisionShape3D.new()
		var floor_box := BoxShape3D.new()
		floor_box.size = Vector3(CELL_SIZE, 0.5, CELL_SIZE)
		floor_shape.shape = floor_box
		floor_shape.position = local + Vector3(0.0, -0.25, 0.0)
		floor_body.add_child(floor_shape)

		if visuals_enabled:
			var tile := MeshInstance3D.new()
			tile.mesh = floor_mesh
			tile.position = local + Vector3(0.0, 0.015, 0.0)
			floor_visual.add_child(tile)

	for cell in cells:
		for side in range(4):
			var neighbour := cell + _side_cell_offset(side)
			if _cells.has(neighbour):
				continue
			# Проём оставляем только в центральной клетке той стороны,
			# где есть дверь. Остальное - стена.
			if doors.has(side) and _is_center_door_cell(cell, side):
				continue
			_add_wall(wall_body, wall_visual, cell, side, wall_material)

	for side in doors.keys():
		var state: int = int(doors[side])
		if state != FloorPlan.DoorState.CRACKED_WALL:
			_add_door_frame(wall_visual, side, wall_material,
				state == FloorPlan.DoorState.OPEN)
		# Для CRACKED_WALL рамку, жаровни и баннер не строим вообще - секретная
		# стена по спеке не должна отличаться от соседней стены, пока её не
		# подорвут бомбой во втором плане.
		_create_door_blocker(wall_body, wall_visual, side, wall_material, state)
		set_door_state(side, state)

	# Потолок строится только при visuals_enabled: в обучении камеры нет,
	# а сотня лишних коллизионных форм на каждой из шестнадцати арен -
	# чистая трата. На физику боя потолок не влияет, никто не прыгает.
	if visuals_enabled:
		_add_ceiling(cells, wall_material)


## Перекрытие над комнатой: плита на каждую клетку пола.
##
## Коллизия обязательна, а не только меш. За неё цепляется SpringArm камеры:
## без коллизии камера при взгляде сверху вниз ушла бы ЗА потолок и показала
## бы ровно то, что потолок и должен закрывать - пустоту за комнатой.
##
## Плиты идут по клеткам, а не одним прямоугольником, потому что комната
## бывает Г-образной и крестовой: сплошная плита накрыла бы и пустые клетки.
func _add_ceiling(cells: Array[Vector2i], material: StandardMaterial3D) -> void:
	var body := StaticBody3D.new()
	body.name = "CeilingCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)

	var visual := Node3D.new()
	visual.name = "CeilingVisual"
	add_child(visual)

	var mat := material.duplicate() as StandardMaterial3D
	# Снизу плита всегда в тени: солнце светит сверху и до неё не достаёт.
	# Без затемнения потолок оказывается светлее стен, и комната выглядит
	# так, будто крыша сама себя освещает.
	mat.albedo_color = mat.albedo_color.darkened(0.45)

	var mesh := BoxMesh.new()
	var size := Vector3(CELL_SIZE, CEILING_THICKNESS, CELL_SIZE)
	mesh.size = size
	mesh.material = mat

	var y := WALL_HEIGHT + CEILING_THICKNESS * 0.5
	for cell in cells:
		var local := _cell_position(cell) + Vector3(0.0, y, 0.0)

		var slab := MeshInstance3D.new()
		slab.mesh = mesh
		slab.position = local
		visual.add_child(slab)

		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		shape.position = local
		body.add_child(shape)

		# Светильник через каждые LAMP_STEP клеток. Перекрытие отрезает
		# направленный свет, а окружающее берётся от почти ночного неба, и
		# без собственных ламп закрытая комната становится буквально чёрной:
		# факелы стоят только у дверей и до середины зала не достают.
		if posmod(cell.x, LAMP_STEP) == 0 and posmod(cell.y, LAMP_STEP) == 0:
			_add_lamp(visual, local + Vector3(0.0, -CEILING_THICKNESS, 0.0))


func _add_lamp(root: Node3D, pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.name = "CeilingLamp"
	light.position = pos
	light.light_color = Color(1.0, 0.74, 0.45)
	light.light_energy = LAMP_ENERGY
	light.omni_range = LAMP_RANGE
	light.omni_attenuation = 1.4
	# Тени выключены намеренно. Ламп в зале до десятка, комнаты не удаляются
	# и копятся по ходу забега; десяток теневых источников на комнату сложился
	# бы в неподъёмное число проходов теней уже к третьей комнате.
	light.shadow_enabled = false
	root.add_child(light)


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat


func _cell_position(cell: Vector2i) -> Vector3:
	return Vector3(float(cell.x) * CELL_SIZE, 0.0, float(cell.y) * CELL_SIZE)


func _side_cell_offset(side: int) -> Vector2i:
	match side:
		0: return Vector2i(0, -1) # north
		1: return Vector2i(0, 1)  # south
		2: return Vector2i(1, 0)  # east
		_: return Vector2i(-1, 0) # west


func _side_center(side: int) -> Vector3:
	match side:
		0: return Vector3(0.0, 0.0, (float(_min_cell.y) - 0.5) * CELL_SIZE)
		1: return Vector3(0.0, 0.0, (float(_max_cell.y) + 0.5) * CELL_SIZE)
		2: return Vector3((float(_max_cell.x) + 0.5) * CELL_SIZE, 0.0, 0.0)
		_: return Vector3((float(_min_cell.x) - 0.5) * CELL_SIZE, 0.0, 0.0)


func _is_center_door_cell(cell: Vector2i, side: int) -> bool:
	if side == 0 or side == 1:
		return cell.x == 0
	return cell.y == 0


func _wall_transform(cell: Vector2i, side: int) -> Array:
	var p := _cell_position(cell)
	var size := Vector3(CELL_SIZE, WALL_HEIGHT, WALL_THICKNESS)
	match side:
		0:
			p.z -= CELL_SIZE * 0.5
		1:
			p.z += CELL_SIZE * 0.5
		2:
			p.x += CELL_SIZE * 0.5
			size = Vector3(WALL_THICKNESS, WALL_HEIGHT, CELL_SIZE)
		_:
			p.x -= CELL_SIZE * 0.5
			size = Vector3(WALL_THICKNESS, WALL_HEIGHT, CELL_SIZE)
	return [p + Vector3.UP * (WALL_HEIGHT * 0.5), size]


## with_collision=false пропускает создание коллизионной формы - используется
## для центральной клетки CRACKED_WALL, где коллизию проёма уже даёт отдельный
## DoorBlocker_<side> (он толще обычной стены, см. _door_transform), и вторая
## коллизионная форма поверх него была бы лишним нахлёстом.
## Возвращает созданный визуальный меш (или null при visuals_enabled=false),
## чтобы вызывающий код мог переиспользовать фасад стены как панель секретной
## двери - см. _build_secret_wall_panel.
func _add_wall(body: StaticBody3D, visual_root: Node3D, cell: Vector2i,
		 side: int, material: StandardMaterial3D,
		 with_collision: bool = true) -> MeshInstance3D:
	var data := _wall_transform(cell, side)
	if with_collision:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = data[1]
		shape.shape = box
		shape.position = data[0]
		body.add_child(shape)

	if visual_root == null:
		return null
	var mesh := MeshInstance3D.new()
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = data[1]
	# Inset the visible facade while keeping the original collision envelope.
	# Pillars and braziers can then project from it without entering walkable space.
	if side < 2:
		wall_mesh.size.z = 0.26
	else:
		wall_mesh.size.x = 0.26
	wall_mesh.material = material
	mesh.mesh = wall_mesh
	mesh.position = data[0]
	visual_root.add_child(mesh)
	var decor := load("res://scripts/FortressDecor.gd")
	decor.wall_detail(visual_root, mesh.position, side, cell)
	return mesh


## Единое правило цвета рамки двери - вызывается и при постройке
## (_add_door_frame), и при смене состояния (set_door_state), чтобы решение
## «какой цвет у какого состояния» не разъехалось по двум местам. Открыто -
## холодный металл без свечения, заперто (бой или ключ - разницы для рамки
## нет) - тёплый акцент со свечением.
func _apply_frame_look(mat: StandardMaterial3D, is_open: bool) -> void:
	mat.albedo_color = Color(0.66, 0.70, 0.76) if is_open else Color(0.90, 0.76, 0.54)
	mat.emission_enabled = not is_open
	mat.emission = Color(0.75, 0.28, 0.08)
	mat.emission_energy_multiplier = 0.12


func _add_door_frame(visual_root: Node3D, side: int,
		material: StandardMaterial3D, is_open: bool) -> void:
	# _add_door_frame теперь вызывается только для реально существующих
	# дверей из словаря doors, не считая CRACKED_WALL (у секретной стены рамки
	# нет вообще - см. вызов в _build), поэтому проверка на «нет двери» здесь
	# не нужна.
	if visual_root == null:
		return
	var center := _side_center(side)
	center.y = 0.0
	var accent := material.duplicate() as StandardMaterial3D
	_apply_frame_look(accent, is_open)
	# Сохраняем материал по стороне: set_door_state перекрашивает именно его,
	# а не создаёт новый, поэтому дверь после боя/ключа и её рамка не могут
	# разъехаться по состоянию (см. Правку 3 ревью задачи 6).
	_frame_materials[side] = accent

	var vertical_size := Vector3(0.34, WALL_HEIGHT, 0.42)
	var horizontal_size := Vector3(DOOR_WIDTH + 0.7, 0.38, 0.42)
	var offset_a := Vector3(-DOOR_WIDTH * 0.5 - 0.15, WALL_HEIGHT * 0.5, 0.0)
	var offset_b := Vector3(DOOR_WIDTH * 0.5 + 0.15, WALL_HEIGHT * 0.5, 0.0)
	if side == 2 or side == 3:
		vertical_size = Vector3(0.42, WALL_HEIGHT, 0.34)
		horizontal_size = Vector3(0.42, 0.38, DOOR_WIDTH + 0.7)
		offset_a = Vector3(0.0, WALL_HEIGHT * 0.5, -DOOR_WIDTH * 0.5 - 0.15)
		offset_b = Vector3(0.0, WALL_HEIGHT * 0.5, DOOR_WIDTH * 0.5 + 0.15)

	_add_frame_piece(visual_root, center + offset_a, vertical_size, accent)
	_add_frame_piece(visual_root, center + offset_b, vertical_size, accent)
	_add_frame_piece(visual_root, center + Vector3.UP * WALL_HEIGHT, horizontal_size, accent)
	var decor := load("res://scripts/FortressDecor.gd")
	decor.entrance_details(visual_root, center, side)


func _add_frame_piece(root: Node3D, pos: Vector3, size: Vector3,
		material: StandardMaterial3D) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	mesh.mesh = box
	mesh.position = pos
	root.add_child(mesh)


func _create_door_blocker(body: StaticBody3D, visual_root: Node3D,
		side: int, material: StandardMaterial3D, state: int) -> void:
	var data := _door_transform(side)
	var blocker := CollisionShape3D.new()
	blocker.name = "DoorBlocker_%d" % side
	var shape := BoxShape3D.new()
	shape.size = data[1]
	blocker.shape = shape
	blocker.position = data[0]
	body.add_child(blocker)
	_blockers[side] = blocker

	if not visuals_enabled:
		return

	if state == FloorPlan.DoorState.CRACKED_WALL:
		# Секретная стена: панель маскируется под обычный сегмент стены, а не
		# под кованые ворота - см. _build_secret_wall_panel.
		_panels[side] = _build_secret_wall_panel(visual_root, side, material)
		return

	var panel := MeshInstance3D.new()
	panel.name = "ClosedDoor_%d" % side
	panel.position = data[0]
	add_child(panel)
	var decor := load("res://scripts/FortressDecor.gd")
	decor.gate(panel, side)
	_panels[side] = panel


## Клетка на границе комнаты, где стена стороны side пропускает проём под
## дверь - та же клетка, что даёт true в _is_center_door_cell(cell, side).
func _center_door_cell(side: int) -> Vector2i:
	match side:
		0: return Vector2i(0, _min_cell.y)
		1: return Vector2i(0, _max_cell.y)
		2: return Vector2i(_max_cell.x, 0)
		_: return Vector2i(_min_cell.x, 0)


## Панель CRACKED_WALL обязана быть неотличима от соседней стены снаружи -
## по спеке секретка «не на карте», вход в неё только через подрыв бомбой
## (второй план). Переиспользуем визуальную часть _add_wall на центральной
## клетке двери: тот же side и материал дают точно тот же BoxMesh.size и тот
## же отступ фасада (0.26), что и у соседнего сегмента стены - без этого
## переиспользования пришлось бы дублировать магические числа инсета и
## получить либо нарост, либо провал в стене.
##
## ЗАМЕТКА ДЛЯ ВТОРОГО ПЛАНА (бомбы/подрыв): set_door_state(side, OPEN) прячет
## эту панель и выключает DoorBlocker_<side> - этого достаточно для пролома.
## Но _add_wall ниже, как и для любой обычной стены, вызывает
## FortressDecor.wall_detail() и вешает на WallVisual WallCornice/WallFooting
## (и WallPillar, если клетка попала в шаг колонн) - при открытии пролома эти
## накладки сами не исчезнут и останутся висеть в воздухе. Второй план обязан
## убрать/спрятать их вместе с открытием двери.
func _build_secret_wall_panel(visual_root: Node3D, side: int,
		material: StandardMaterial3D) -> MeshInstance3D:
	var door_cell := _center_door_cell(side)
	# with_collision=false: коллизию проёма уже даёт DoorBlocker_<side> выше.
	var mesh := _add_wall(null, visual_root, door_cell, side, material, false)
	if mesh == null:
		return null
	# Меш родился в WallVisual (как и обычная стена) - переносим его в саму
	# комнату и переименовываем в ClosedDoor_<side>, чтобы к нему обращались
	# ровно так же, как к панели любой другой двери (room.get_node(...),
	# set_door_state).
	visual_root.remove_child(mesh)
	add_child(mesh)
	mesh.name = "ClosedDoor_%d" % side
	return mesh


func _door_transform(side: int) -> Array:
	var center := _side_center(side) + Vector3.UP * (WALL_HEIGHT * 0.5)
	var size := Vector3(DOOR_WIDTH, WALL_HEIGHT, WALL_THICKNESS + 0.12)
	if side == 2 or side == 3:
		size = Vector3(WALL_THICKNESS + 0.12, WALL_HEIGHT, DOOR_WIDTH)
	return [center, size]


func set_door_state(side: int, state: int) -> void:
	if not doors.has(side):
		return
	doors[side] = state
	var open := state == FloorPlan.DoorState.OPEN
	var blocker: CollisionShape3D = _blockers.get(side)
	if blocker != null:
		# set_deferred обязателен: форму нельзя включать и выключать изнутри
		# физического шага, в котором её может опрашивать сервер.
		blocker.set_deferred("disabled", open)
	var panel: MeshInstance3D = _panels.get(side)
	if panel != null:
		panel.visible = not open
	var accent: StandardMaterial3D = _frame_materials.get(side)
	if accent != null:
		# У CRACKED_WALL рамки нет вообще - тогда _frame_materials.get(side)
		# вернёт null, и перекрашивать нечего.
		_apply_frame_look(accent, open)


## Есть ли дверь на этой стороне, в любом состоянии (включая CRACKED_WALL).
## Отдельная функция, а не проверка door_state(): у стороны без двери
## door_state всё равно обязана что-то вернуть (см. её комментарий ниже), и
## это значение - не признак настоящего запертого боем прохода.
func has_door(side: int) -> bool:
	return doors.has(side)


## Внимание: для стороны, где двери нет вообще, возвращает
## LOCKED_BY_FIGHT - это лишь «безопасное» значение по умолчанию, а не
## признак существующего запертого боем прохода. Перед тем как опираться на
## результат, сначала проверь has_door(side).
func door_state(side: int) -> int:
	return int(doors.get(side, FloorPlan.DoorState.LOCKED_BY_FIGHT))


func open_sides() -> Array[int]:
	var out: Array[int] = []
	for side in doors.keys():
		if int(doors[side]) == FloorPlan.DoorState.OPEN:
			out.append(side)
	return out


## Точка в мировых координатах по центру проёма. Используется и для подсказки
## «дверь открыта», и для переноса бойцов в соседнюю комнату.
func door_position(side: int) -> Vector3:
	return to_global(_side_center(side) + Vector3.UP * 0.15)


## Точка внутри комнаты, на шаг от двери: сюда ставим бойцов после перехода,
## чтобы они не оказались в самом проёме и не перешли обратно тем же кадром.
func inside_door_position(side: int) -> Vector3:
	var inward := -DungeonRoom.side_direction(side) * CELL_SIZE
	return to_global(_side_center(side) + inward + Vector3.UP * 0.15)


func get_random_floor_position(rng: RandomNumberGenerator) -> Vector3:
	var keys: Array = _cells.keys()
	if keys.is_empty():
		return global_position
	var cell: Vector2i = keys[rng.randi_range(0, keys.size() - 1)]
	# Origin Zombie должен стоять на y=0: его капсула начинается на полу
	# благодаря Collision.position.y=0.8 и высоте 1.6.
	return to_global(_cell_position(cell))


static func opposite_side(side: int) -> int:
	match side:
		0: return 1
		1: return 0
		2: return 3
		_: return 2


static func side_direction(side: int) -> Vector3:
	match side:
		0: return Vector3(0.0, 0.0, -1.0)
		1: return Vector3(0.0, 0.0, 1.0)
		2: return Vector3(1.0, 0.0, 0.0)
		_: return Vector3(-1.0, 0.0, 0.0)


func get_half_extents() -> Vector3:
	return Vector3(
		(float(_max_cell.x - _min_cell.x + 1) * CELL_SIZE) * 0.5,
		0.0,
		(float(_max_cell.y - _min_cell.y + 1) * CELL_SIZE) * 0.5)

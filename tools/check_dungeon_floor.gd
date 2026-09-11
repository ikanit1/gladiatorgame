extends Node

## Стыковка дверей в МИРОВЫХ координатах. Именно здесь ловятся расхождения
## габарита и шага сетки: если они разойдутся, между комнатами появится щель
## или комнаты налезут друг на друга, а на глаз это заметно не сразу.
##
## Дополнение к плану: enter_cell строит клетку и всех её соседей по дверям
## заранее - этой же функцией дальше пользуется каждый переход через дверь
## (задача 13), поэтому его поведение проверяем здесь же, отдельно от простой
## постройки всего этажа циклом ниже. Главное, что тут нужно поймать - именно
## ленивость: что НЕ построенные соседями клетки остаются непостроенными.

func _ready() -> void:
	var r := TestReport.new("DungeonFloor")
	var rng := RandomNumberGenerator.new()
	rng.seed = 99

	for attempt in range(12):
		var plan := FloorPlan.generate(rng.randi_range(1, 5), rng)
		var floor_node := DungeonFloor.new()
		add_child(floor_node)
		floor_node.setup(plan, false)

		# Шаг сетки обязан совпадать с габаритом комнаты
		var c0 := floor_node.world_center_of(Vector2i(0, 0))
		var cx := floor_node.world_center_of(Vector2i(1, 0))
		var cz := floor_node.world_center_of(Vector2i(0, 1))
		r.in_range(cx.x - c0.x, RoomGenerator.ROOM_WIDTH, RoomGenerator.ROOM_WIDTH,
			"шаг сетки по x равен ширине комнаты")
		r.in_range(cz.z - c0.z, RoomGenerator.ROOM_DEPTH, RoomGenerator.ROOM_DEPTH,
			"шаг сетки по z равен глубине комнаты")

		# --- Дополнение: enter_cell строит клетку и соседей, но не весь этаж ---

		var built_signals: Array[Vector2i] = []
		floor_node.room_built.connect(func(cell: Vector2i, _room: DungeonRoom) -> void: built_signals.append(cell))

		var start_room := floor_node.enter_cell(FloorPlan.START_CELL)
		r.check(start_room != null, "enter_cell(START_CELL) вернул комнату")
		r.eq(floor_node.current_cell, FloorPlan.START_CELL,
			"enter_cell выставляет current_cell")
		r.check(floor_node.current_room() == start_room,
			"current_room() возвращает ту же комнату, что вернул enter_cell")

		var start_doors := plan.doors_of(FloorPlan.START_CELL)
		var expected_built := {FloorPlan.START_CELL: true}
		for side in start_doors.keys():
			var neighbour: Vector2i = FloorPlan.START_CELL + FloorPlan.SIDE_OFFSETS[side]
			expected_built[neighbour] = true
			r.check(floor_node.built_room(neighbour) != null,
				"enter_cell строит соседа %s стартовой клетки по двери" % neighbour)

		# Ленивость - главная идея задачи: комнаты, не соседние со стартом,
		# ещё не построены. Без этой проверки поломка "строить всё сразу"
		# прошла бы молча - built_room(neighbour) != null был бы true и в
		# сломанной версии тоже.
		var checked_unbuilt := false
		for cell in plan.rooms.keys():
			if expected_built.has(cell):
				continue
			checked_unbuilt = true
			r.check(floor_node.built_room(cell) == null,
				"комната %s не соседняя со стартом ещё не построена (ленивость)" % cell)
		if not checked_unbuilt:
			print("  внимание: на попытке %d все комнаты этажа соседствуют со стартом, ленивость не проверена" % attempt)

		# Кеш: повторный room_at для той же клетки возвращает тот же объект,
		# а не строит второй раз (второй setup() на той же DungeonRoom
		# пишет push_error - см. DungeonRoom._build).
		var again := floor_node.room_at(FloorPlan.START_CELL)
		r.check(again == start_room, "повторный room_at возвращает тот же объект (кеш)")

		# enter_cell для клетки без комнаты - null, current_cell не меняется
		var cell_before := floor_node.current_cell
		var missing := floor_node.enter_cell(Vector2i(-5, -5))
		r.check(missing == null, "enter_cell в клетку без комнаты возвращает null")
		r.eq(floor_node.current_cell, cell_before,
			"enter_cell в клетку без комнаты не меняет current_cell")

		# Сигнал room_built - ровно один раз на каждую клетку, построенную к
		# этому моменту (старт + его соседи по дверям), без дублей.
		r.eq(built_signals.size(), expected_built.size(),
			"room_built испущен по разу на каждую построенную клетку")
		var seen := {}
		for cell in built_signals:
			r.check(not seen.has(cell), "room_built не дублируется для %s" % cell)
			seen[cell] = true

		# --- Конец дополнения ---

		# Строим все комнаты и сверяем двери соседей
		for cell in plan.rooms.keys():
			floor_node.room_at(cell)
		await get_tree().process_frame

		for cell in plan.rooms.keys():
			var room: DungeonRoom = floor_node.room_at(cell)
			r.check(room != null, "комната %s построена" % cell)
			for side in plan.doors_of(cell).keys():
				var other: Vector2i = cell + FloorPlan.SIDE_OFFSETS[side]
				var other_room: DungeonRoom = floor_node.room_at(other)
				var back_side := FloorPlan.opposite_side(side)
				var here := room.door_position(side)
				var there := other_room.door_position(back_side)
				r.in_range(here.distance_to(there), 0.0, 0.05,
					"проёмы %s сторона %d и %s сторона %d совпадают"
						% [cell, side, other, back_side])

		# side_between обязана согласовываться со смещениями сетки
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(3, 2)), 0, "север")
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(3, 4)), 1, "юг")
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(4, 3)), 2, "восток")
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(2, 3)), 3, "запад")

		floor_node.queue_free()
		await get_tree().process_frame

	r.finish(get_tree())

extends SceneTree

## 2000 планировок на этаж. Проверки — приёмочные условия из спеки.

func _init() -> void:
	var r := TestReport.new("FloorPlan")
	var rng := RandomNumberGenerator.new()
	rng.seed = 777

	for floor_number in range(1, ThreatCurve.FLOOR_COUNT + 1):
		var min_rooms := 99
		var max_rooms := 0
		for i in range(2000):
			var plan := FloorPlan.generate(floor_number, rng)

			min_rooms = mini(min_rooms, plan.room_count())
			max_rooms = maxi(max_rooms, plan.room_count())

			# Связность: каждая комната должна иметь расстояние от старта
			for cell in plan.rooms.keys():
				if cell == plan.secret_cell:
					continue   # секретка вне обычного обхода
				r.check(plan.distances.has(cell),
					"комната %s недостижима от старта (этаж %d)" % [cell, floor_number])

			# Старт на месте и он один
			r.check(plan.has_room(FloorPlan.START_CELL), "стартовая клетка существует")
			r.eq(plan.type_count(FloorPlan.RoomType.START), 1, "ровно один старт")

			# В сетку вписались
			for cell in plan.rooms.keys():
				r.check(cell.x >= 0 and cell.x < FloorPlan.GRID_W
					and cell.y >= 0 and cell.y < FloorPlan.GRID_H,
					"клетка %s вне сетки" % cell)

			# Спец-комнаты обязаны быть на каждом этаже
			r.eq(plan.type_count(FloorPlan.RoomType.BOSS), 1,
				"ровно одна комната босса (этаж %d)" % floor_number)
			r.eq(plan.type_count(FloorPlan.RoomType.TREASURE), 1,
				"ровно одна сокровищница (этаж %d)" % floor_number)
			r.eq(plan.type_count(FloorPlan.RoomType.SECRET), 1,
				"ровно одна секретка (этаж %d)" % floor_number)
			if floor_number >= 2:
				r.eq(plan.type_count(FloorPlan.RoomType.SHOP), 1,
					"ровно одна лавка (этаж %d)" % floor_number)
			else:
				r.eq(plan.type_count(FloorPlan.RoomType.SHOP), 0,
					"на первом этаже лавки нет")

			# Главное ограничение: босс не ближе четырёх шагов от старта
			r.ge(float(int(plan.distances.get(plan.boss_cell, 0))),
				float(FloorPlan.MIN_BOSS_DISTANCE),
				"босс не ближе %d шагов (этаж %d)" % [FloorPlan.MIN_BOSS_DISTANCE, floor_number])

			# Двери: у каждой пары соседей дверь с обеих сторон и согласованная
			for cell in plan.rooms.keys():
				var doors := plan.doors_of(cell)
				for side in doors.keys():
					var other: Vector2i = cell + FloorPlan.SIDE_OFFSETS[side]
					r.check(plan.has_room(other),
						"дверь %s на сторону %d ведёт в пустоту" % [cell, side])
					var back := plan.doors_of(other)
					var back_side := FloorPlan.opposite_side(side)
					r.check(back.has(back_side),
						"у соседа %s нет ответной двери" % other)
					if back.has(back_side):
						r.eq(back[back_side], doors[side],
							"состояния двери %s<->%s расходятся" % [cell, other])

			# Секретка соседствует хотя бы с одной обычной комнатой
			var secret_links := 0
			for offset in FloorPlan.SIDE_OFFSETS:
				if plan.has_room(plan.secret_cell + offset):
					secret_links += 1
			r.ge(float(secret_links), 1.0, "секретка примыкает к комнате")

		r.in_range(float(min_rooms), 8.0, 30.0,
			"минимум комнат на этаже %d в разумных границах" % floor_number)
		r.in_range(float(max_rooms), 8.0, 30.0,
			"максимум комнат на этаже %d в разумных границах" % floor_number)
		print("  этаж %d: комнат %d..%d" % [floor_number, min_rooms, max_rooms])

	var hist := {}
	for i in range(2000):
		var plan := FloorPlan.generate(1, rng)
		var d := int(plan.distances.get(plan.boss_cell, 0))
		hist[d] = int(hist.get(d, 0)) + 1
	var keys := hist.keys()
	keys.sort()
	var parts: Array[String] = []
	for d in keys:
		parts.append("%d шагов: %d" % [d, hist[d]])
	print("  распределение расстояния до босса на первом этаже — " + ", ".join(parts))

	r.finish(self)

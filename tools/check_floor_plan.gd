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

		r.in_range(float(min_rooms), 8.0, 30.0,
			"минимум комнат на этаже %d в разумных границах" % floor_number)
		r.in_range(float(max_rooms), 8.0, 30.0,
			"максимум комнат на этаже %d в разумных границах" % floor_number)
		print("  этаж %d: комнат %d..%d" % [floor_number, min_rooms, max_rooms])

	r.finish(self)

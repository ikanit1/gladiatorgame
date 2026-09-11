extends SceneTree

## Фиксированный габарит - условие, без которого комнаты не складываются в
## сетку. Центральные клетки сторон обязаны существовать у ЛЮБОГО контура:
## именно через них проходят двери.

func _init() -> void:
	var r := TestReport.new("RoomGenerator")
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242

	r.eq(RoomGenerator.GRID_W, 13, "ширина в клетках")
	r.eq(RoomGenerator.GRID_D, 11, "глубина в клетках")
	r.in_range(RoomGenerator.ROOM_WIDTH, 26.0, 26.0, "ширина в метрах")
	r.in_range(RoomGenerator.ROOM_DEPTH, 22.0, 22.0, "глубина в метрах")

	var hx := RoomGenerator.GRID_W / 2
	var hz := RoomGenerator.GRID_D / 2

	for shape in RoomGenerator.SHAPES:
		var cfg := {"shape": shape, "grid_w": RoomGenerator.GRID_W, "grid_d": RoomGenerator.GRID_D}
		var cells: Array[Vector2i] = RoomGenerator.cells_for(cfg)
		r.check(not cells.is_empty(), "контур %s непустой" % shape)

		var min_cell := cells[0]
		var max_cell := cells[0]
		for cell in cells:
			min_cell.x = mini(min_cell.x, cell.x)
			min_cell.y = mini(min_cell.y, cell.y)
			max_cell.x = maxi(max_cell.x, cell.x)
			max_cell.y = maxi(max_cell.y, cell.y)

		r.eq(min_cell, Vector2i(-hx, -hz), "нижний угол габарита у контура %s" % shape)
		r.eq(max_cell, Vector2i(hx, hz), "верхний угол габарита у контура %s" % shape)

		for edge in [Vector2i(0, -hz), Vector2i(0, hz), Vector2i(-hx, 0), Vector2i(hx, 0)]:
			r.check(cells.has(edge),
				"у контура %s нет центральной клетки стороны %s" % [shape, edge])

	# geometry() обязана отдавать фиксированный габарит и валидный контур
	for i in range(500):
		var cfg := RoomGenerator.geometry(rng)
		r.eq(int(cfg["grid_w"]), RoomGenerator.GRID_W, "geometry отдаёт фиксированную ширину")
		r.eq(int(cfg["grid_d"]), RoomGenerator.GRID_D, "geometry отдаёт фиксированную глубину")
		r.check(RoomGenerator.SHAPES.has(str(cfg["shape"])), "контур из списка")
		r.check(RoomGenerator.THEMES.has(str(cfg["theme"])), "тема из списка")
		r.check(cfg.has("floor_color"), "есть цвет пола")

	r.finish(self)

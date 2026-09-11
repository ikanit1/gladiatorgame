extends Node

## Проверка: полоса над зомби скрыта при полном здоровье, появляется после
## урона и при этом снова начинает разворачиваться к камере.

func _ready() -> void:
	var game: Node = load("res://scenes/Game.tscn").instantiate()
	add_child(game)
	for _i in range(60):
		await get_tree().process_frame

	# Стартовая комната этажа по дизайну пустая, бой идёт только в боевой
	# комнате. Входим в ближайшую боевую тем же путём, что и переход в дверь
	# (_enter_cell): полосе здоровья всё равно, как игрок попал в комнату, а
	# ждать, пока кто-то дойдёт до двери, этой проверке незачем.
	var plan: FloorPlan = game.get("_plan")
	if plan == null:
		print("ПРОВАЛ: этаж не построен")
		get_tree().quit(1)
		return
	var target := Vector2i(-1, -1)
	var entry_side := -1
	var start_doors := plan.doors_of(FloorPlan.START_CELL)
	for side in start_doors.keys():
		var cell: Vector2i = FloorPlan.START_CELL + FloorPlan.SIDE_OFFSETS[side]
		if int(plan.spec(cell)["type"]) == FloorPlan.RoomType.COMBAT:
			target = cell
			entry_side = FloorPlan.opposite_side(side)
			break
	if entry_side < 0:
		for cell in plan.rooms.keys():
			if int(plan.spec(cell)["type"]) != FloorPlan.RoomType.COMBAT:
				continue
			var doors := plan.doors_of(cell)
			if doors.is_empty():
				continue
			target = cell
			entry_side = int(doors.keys()[0])
			break
	game.call("_enter_cell", target, entry_side)
	for _i in range(6):
		await get_tree().process_frame

	var arena = game.get("arena")
	var zombies = arena.get_alive_zombies()
	if zombies.is_empty():
		print("ПРОВАЛ: на арене нет зомби")
		get_tree().quit(1)
		return

	var z = zombies[0]
	var bar = z.get_node_or_null("Visuals/HealthBar3D")
	if bar == null:
		for child in z.find_children("HealthBar3D", "", true, false):
			bar = child
			break
	if bar == null:
		print("ПРОВАЛ: не найден узел HealthBar3D")
		get_tree().quit(1)
		return

	var whole: bool = bar.visible
	var whole_proc: bool = bar.is_processing()

	z.take_damage(20.0, z.global_position + Vector3.FORWARD)
	for _i in range(6):
		await get_tree().process_frame

	var hurt: bool = bar.visible
	var hurt_proc: bool = bar.is_processing()

	print("целый зомби:  полоса видна=%s  разворот=%s   (ожидалось нет/нет)" % [whole, whole_proc])
	print("раненый:      полоса видна=%s  разворот=%s   (ожидалось да/да)" % [hurt, hurt_proc])
	var ok: bool = not whole and not whole_proc and hurt and hurt_proc
	print("ИТОГ: " + ("ок" if ok else "ПРОВАЛ"))
	get_tree().quit(0 if ok else 1)

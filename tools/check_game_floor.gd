extends Node

## Интеграционная проверка среза 13a: этаж, переходы, бой за комнату, двери.
##
## Поднимает НАСТОЯЩИЙ res://scenes/Game.tscn с фиксированным сидом забега и
## проходит этаж так, как его проходит игрок: подводит бойца к проёму и крутит
## кадры физики, пока FloorRunner сам не переведёт его в соседнюю комнату.
## Навигация этажа читается через публичное API FloorRunner (game.floor_runner),
## без рефлексии в приватное.
## Прямой вызов enter_cell остаётся только для пустого набора врагов - там
## нужен именно бой без единого заспавненного зомби, а дойти до такой комнаты
## пешком проверке незачем.
##
## Запуск сценой (не --script): GameScreen обращается к автозагрузке GameConfig,
## а в режиме --script автозагрузок не существует.
##
## user://settings.cfg проверка НЕ пишет: кооператив и сложность выставляются
## только в памяти автозагрузки, save_settings() не зовётся.

## Сид подобран поиском по FloorPlan.generate: у стартовой комнаты четыре
## двери - две в бой, одна в сокровищницу и треснувшая стена в секретку,
## открытая в срезе 1. Так проверяются все виды доступных дверей сразу.
const RUN_SEED := 14
## Сколько кадров физики даём на подход к двери: 4 м при скорости 5 м/с - это
## меньше секунды, запас на разгон и на заминку от удара.
const WALK_FRAMES := 300
const MIN_SPAWN_DISTANCE := 6.0
## FloorRunner.DOOR_REACH - дублируем числом, а не читаем константу: константу
## проверяемого кода проверка обязана подтверждать, а не брать на веру.
const DOOR_REACH := 1.6
## Запас от точки бойца до края пола, при котором капсула (радиус 0.4) не
## задевает стену (половина толщины 0.3 заходит внутрь комнаты).
const FLOOR_CLEARANCE := 0.7
## Насколько вперёд бойца и камеры обязаны смотреть внутрь комнаты после
## входа: косинус угла, 0.7 - это примерно 45 градусов.
const FACING_MIN_DOT := 0.7

var r := TestReport.new("GameFloor")
var game: Node3D
var arena: Arena
var runner: FloorRunner
var _cam: Camera3D
var _walk := Vector3.ZERO
## Куда смотрит игрок во время ходьбы; ноль - туда же, куда идёт.
var _face := Vector3.ZERO
## Остановить ходьбу в самый момент перехода: так ведёт себя игрок, который
## отпустил клавиши, едва оказавшись в новой комнате.
var _stop_on_entry := false
var _entries: Array[Dictionary] = []
## Массив, а не int: лямбда захватывает локальные по значению (см.
## check_arena_encounter.gd), массив же - по ссылке.
var _cleared_signals := [0]


func _ready() -> void:
	# Раньше гладиатора: намерение движения обязано быть выставлено до того,
	# как Gladiator._physics_process его прочитает.
	process_physics_priority = -50

	GameConfig.coop = true
	GameConfig.difficulty = GameConfig.Difficulty.NORMAL

	game = load("res://scenes/Game.tscn").instantiate()
	game.set("run_seed", RUN_SEED)
	add_child(game)
	arena = game.get("arena")
	runner = game.get("floor_runner")
	_cam = game.get_node("CameraRig/Camera3D") as Camera3D
	runner.room_entered.connect(_on_room_entered)
	arena.encounter_cleared.connect(func() -> void: _cleared_signals[0] += 1)

	# Игрока ведёт проверка, а не клавиатура. В headless курсор не захвачен, и
	# PlayerInput каждый кадр сбрасывал бы намерения в ноль.
	var input := arena.gladiator.get_node_or_null("PlayerInput")
	if input != null:
		input.process_mode = Node.PROCESS_MODE_DISABLED

	_run_checks.call_deferred()


func _physics_process(_delta: float) -> void:
	if arena == null or _walk == Vector3.ZERO:
		return
	var g := arena.gladiator
	g.human_movement = true
	g.intent_move_world = _walk
	var face := _face if _face != Vector3.ZERO else _walk
	g.intent_facing_yaw = atan2(-face.x, -face.z)


# ------------------------------------------------------------------
# Сценарий
# ------------------------------------------------------------------

func _run_checks() -> void:
	var waited := 0
	while runner.dungeon() == null and waited < 30:
		await get_tree().process_frame
		waited += 1
	await _frames(3)

	var run := runner.run_state()
	var fl := runner.dungeon()
	var plan := runner.plan()
	r.check(run != null, "старт: RunState создан")
	r.check(fl != null and plan != null, "старт: отложенный start_floor построил этаж")
	if run == null or fl == null or plan == null:
		r.finish(get_tree())
		return

	_check_startup(run, fl, plan)
	# Подсказку двери FloorRunner считает в tick(), то есть в кадре _process
	# GameScreen. После тяжёлой постройки этажа три кадра физики выше могли
	# пройти одной итерацией догона, раньше первого _process, - ждём два.
	await get_tree().process_frame
	await get_tree().process_frame
	r.ge(runner.door_hint_distance(), 0.0, "API: у открытой двери старта есть подсказка")
	var types := {}
	for c in plan.rooms.keys():
		var tn: String = FloorPlan.RoomType.keys()[int(plan.spec(c)["type"])]
		types[tn] = int(types.get(tn, 0)) + 1
	print("  этаж 1, сид %d: комнат %d, по типам %s, дверей у старта %d" % [
		RUN_SEED, plan.room_count(), types, plan.doors_of(FloorPlan.START_CELL).size()])

	# --- Каждая доступная дверь стартовой комнаты ---
	var start_doors := plan.doors_of(FloorPlan.START_CELL)
	var sides: Array = start_doors.keys()
	sides.sort()
	var first_fight_side := -1
	var fights := 0
	var walked := 0
	for side in sides:
		if int(start_doors[side]) == FloorPlan.DoorState.LOCKED_BY_KEY:
			continue   # запертые на ключ двери - второй план
		walked += 1
		var target: Vector2i = FloorPlan.START_CELL + FloorPlan.SIDE_OFFSETS[side]
		var back := FloorPlan.opposite_side(side)
		var target_type := int(plan.spec(target)["type"])
		var was_cleared := run.is_cleared(target)

		var label := "дверь старта %d -> %s" % [side, target]
		var e := await _walk_through(side, label)
		if e.is_empty():
			_recover_to_start()
			await _frames(5)
			continue
		# След прогона: что именно проверено, а не только сколько раз.
		print("  %s: %s, дверь в плане %s, врагов %d, ближайший зомби %.2f м" % [
			label, FloorPlan.RoomType.keys()[target_type],
			FloorPlan.DoorState.keys()[int(start_doors[side])],
			(e["zombies"] as Array).size(), _nearest_zombie(e)])
		_check_entry(e, target, back, label)
		await _frames(2)
		_check_door_sync(label + ": после входа")

		var is_fight := not was_cleared and target_type in [
			FloorPlan.RoomType.COMBAT, FloorPlan.RoomType.BOSS, FloorPlan.RoomType.LOCKED]
		if is_fight:
			fights += 1
			var first := first_fight_side < 0
			if first:
				first_fight_side = side
			await _fight_room(e, target, back, label, run, plan)
			if first:
				# Раненый игрок и поверженный напарник уходят через дверь
				arena.gladiator.health = 33.0
				var ally := arena.ally
				if ally != null:
					ally.take_damage(1.0e6, ally.global_position + Vector3(1.0, 0.0, 0.0))
					r.check(ally.is_downed(), "подготовка: напарник повержен перед переходом")
		else:
			r.eq((e["zombies"] as Array).size(), 0, label + ": в комнате без боя врагов нет")
			_check_doors_expected(false, label + ": комната без боя")

		var e2 := await _walk_through(back, label + ": обратно")
		if e2.is_empty():
			_recover_to_start()
			await _frames(5)
			continue
		_check_entry(e2, FloorPlan.START_CELL, side, label + ": обратно")

		if is_fight and first_fight_side == side:
			r.in_range(float(e2["player_health"]), 33.0, 33.0,
				"раненое здоровье игрока пережило переход через дверь")
			if arena.ally != null:
				r.check(bool(e2["ally_downed"]),
					"поверженный напарник остался повержен после перехода")
				r.in_range(arena.ally.max_health, 70.0, 70.0,
					"максимум здоровья напарника после перехода не сброшен")
				arena.ally.revive()
			arena.gladiator.health = arena.gladiator.max_health
		_heal_team()

	r.ge(float(walked), 1.0, "у стартовой комнаты есть хотя бы одна доступная дверь")
	r.ge(float(fights), 1.0,
		"сид даёт боевую комнату рядом со стартом - иначе бой не проверен")

	# --- Повторный вход в зачищенную комнату ---
	if first_fight_side >= 0:
		var target: Vector2i = FloorPlan.START_CELL + FloorPlan.SIDE_OFFSETS[first_fight_side]
		var cleared_before := run.cleared.size()
		var signals_before: int = _cleared_signals[0]
		var e3 := await _walk_through(first_fight_side, "повторный вход в %s" % target)
		if not e3.is_empty():
			_check_entry(e3, target, FloorPlan.opposite_side(first_fight_side), "повторный вход")
			r.eq((e3["zombies"] as Array).size(), 0, "повторный вход: врагов не поставлено")
			await _frames(30)
			r.eq(arena.get_alive_count(), 0, "повторный вход: врагов нет и спустя 30 кадров")
			r.eq(run.cleared.size(), cleared_before, "повторный вход: отметок зачистки не прибавилось")
			r.eq(_cleared_signals[0], signals_before, "повторный вход: encounter_cleared не пришёл")
			_check_doors_expected(false, "повторный вход")
			_check_door_sync("повторный вход")

	await _check_backward_entry(fl)
	await _check_empty_encounter(run, fl, plan)
	_check_no_quick_bounce()
	await _check_entry_spots_all_shapes()

	r.finish(get_tree())


func _check_startup(run: RunState, fl: DungeonFloor, plan: FloorPlan) -> void:
	r.eq(fl.current_cell, FloorPlan.START_CELL, "старт: текущая клетка - стартовая")
	r.eq(run.floor_number, 1, "старт: первый этаж")
	r.check(run.is_visited(FloorPlan.START_CELL), "старт: стартовая клетка отмечена посещённой")
	r.eq(arena.get_alive_count(), 0, "старт: в стартовой комнате врагов нет")
	r.check(arena.combat_room == fl.current_room(), "старт: арена знает текущую комнату")
	r.eq(_entries.size(), 1, "старт: вход в стартовую клетку испущен один раз")
	if _entries.size() >= 1:
		_check_entry(_entries[0], FloorPlan.START_CELL, -1, "старт")

	# Старая тестовая коробка арены не участвует в этаже
	var env := arena.get_node_or_null("Environment") as Node3D
	r.check(env != null and not env.visible, "старт: коробка арены скрыта")
	if env != null:
		for child in env.get_children():
			if child is CollisionShape3D:
				r.check((child as CollisionShape3D).disabled,
					"старт: коллизия коробки арены %s выключена" % child.name)
	var decor := arena.get_node_or_null("Decor") as Node3D
	r.check(decor == null or not decor.visible, "старт: декор коробки арены скрыт")

	# Слабый старт применён в игре
	r.check(arena.ally != null, "старт: напарник есть (кооператив включён в памяти)")
	for f in arena.get_fighters():
		var who := "игрок" if f == arena.gladiator else "напарник"
		r.in_range(f.max_health, 70.0, 70.0, "слабый старт: максимум здоровья (%s)" % who)
		r.in_range(f.health, 70.0, 70.0, "слабый старт: здоровье (%s)" % who)
		r.in_range(f.block_stamina_max, 70.0, 70.0, "слабый старт: запас щита (%s)" % who)
		r.in_range(f.sword_cooldown, 0.85, 0.85, "слабый старт: кулдаун меча (%s)" % who)
		r.in_range(f.kick_cooldown, 2.2, 2.2, "слабый старт: кулдаун пинка (%s)" % who)
	# ... и только в игре: сцена бойца по-прежнему базовая
	var fresh: Gladiator = load("res://scenes/Gladiator.tscn").instantiate()
	r.in_range(fresh.max_health, 100.0, 100.0, "слабый старт не протёк в Gladiator.tscn")
	fresh.free()

	_check_doors_expected(false, "старт")
	_check_door_sync("старт")

	# Публичное API FloorRunner согласовано с этажом, который он построил
	r.eq(runner.current_cell(), fl.current_cell, "API: current_cell() - клетка этажа")
	r.check(runner.current_room() == fl.current_room(), "API: current_room() - комната этажа")
	var near := runner.nearest_open_door(arena.gladiator.global_position)
	r.check(near in fl.current_room().open_sides(), "API: nearest_open_door() - открытая дверь")
	# Расширение для 13b: состояние клетки переживает повторные обращения
	var st := runner.cell_state(FloorPlan.START_CELL)
	st["probe"] = 1
	r.eq(runner.cell_state(FloorPlan.START_CELL).get("probe", 0), 1,
		"API: cell_state() отдаёт тот же словарь клетки")
	st.erase("probe")


## Бой в только что открытой комнате: число врагов, дистанция спавна,
## запертые двери, зачистка одним сигналом.
func _fight_room(e: Dictionary, cell: Vector2i, entry_side: int, label: String,
		run: RunState, plan: FloorPlan) -> void:
	var room := _current_room()
	var zs: Array = e["zombies"]
	var floor_n := run.floor_number
	var lo := 3 + floor_n
	var hi := 5 + floor_n
	var room_type := int(plan.spec(cell)["type"])
	if room_type == FloorPlan.RoomType.BOSS:
		lo += 3
		hi += 3
	elif room_type == FloorPlan.RoomType.LOCKED:
		lo = int(ceil(lo * ThreatCurve.LOCKED_ROOM_ENEMY_MULT))
		hi = int(ceil(hi * ThreatCurve.LOCKED_ROOM_ENEMY_MULT))
	r.in_range(float(zs.size()), float(lo), float(hi),
		label + ": число врагов из ThreatCurve.enemy_count для этажа %d" % floor_n)
	r.eq(arena.max_alive, zs.size(), label + ": max_alive равен набору")

	var door := room.door_position(entry_side)
	var entry: Vector3 = e["entry"]
	var points := [door, entry, e["player"], e["ally"]]
	var nearest := INF
	for z in zs:
		for p in points:
			if p == Vector3.INF:
				continue
			nearest = minf(nearest, _flat_distance(z, p))
	r.ge(nearest, MIN_SPAWN_DISTANCE - 0.01,
		label + ": ближайший зомби от двери входа и бойцов, м")

	_check_doors_expected(true, label + ": бой")
	_check_door_sync(label + ": бой")

	# Упереться в запертую боем дверь входа: перехода нет, игрок внутри
	var dir := DungeonRoom.side_direction(entry_side)
	var before := _entries.size()
	_teleport_player(door - dir * 3.0, room)
	_walk = dir
	await _frames(90)
	_stop()
	r.eq(_entries.size(), before, label + ": запертая боем дверь не переводит")
	var depth := (door - arena.gladiator.global_position).dot(dir)
	r.ge(depth, 0.3, label + ": запертая боем дверь держит игрока в комнате")
	# Прочь от двери: иначе игрок, прижатый к проёму, ушёл бы в него сразу,
	# как только двери откроются, и сценарий проверки сбился бы.
	_teleport_player(door - dir * 5.0, room)

	var cleared_before := run.cleared.size()
	var signals_before: int = _cleared_signals[0]
	for z in arena.get_alive_zombies():
		z.take_damage(1.0e6, z.global_position + Vector3(1.0, 0.0, 0.0))
	var n := 0
	while _cleared_signals[0] == signals_before and n < 30:
		await get_tree().physics_frame
		n += 1
	await _frames(40)
	r.eq(_cleared_signals[0] - signals_before, 1, label + ": encounter_cleared ровно один")
	r.eq(run.cleared.size() - cleared_before, 1, label + ": ровно одна отметка зачистки")
	r.check(run.is_cleared(cell), label + ": комната отмечена зачищенной")
	_check_doors_expected(false, label + ": после зачистки")
	_check_door_sync(label + ": после зачистки")


## Вход спиной: игрок пятится в проём, глядя назад, в комнату, которую
## покидает, - так отходят, прикрываясь щитом. До перехода и тело, и камера
## смотрят прочь от двери. После перехода оба обязаны смотреть внутрь новой
## комнаты: позиция телепортируется, а поворот тела лишь догоняет намерение,
## и без явного разворота игрок остался бы лицом к решётке за спиной.
##
## Обычный проход через дверь этого не ловит: там игрок идёт лицом вперёд, и
## направление ходьбы через дверь совпадает с направлением внутрь.
func _check_backward_entry(fl: DungeonFloor) -> void:
	var room := _current_room()
	var sides: Array = room.open_sides()
	sides.sort()
	r.check(not sides.is_empty(), "вход спиной: у текущей комнаты есть открытая дверь")
	if sides.is_empty():
		return
	# Предпочтительно - в стартовую: там нет боя, который сбил бы сценарий.
	var side: int = sides[0]
	for s in sides:
		if fl.current_cell + FloorPlan.SIDE_OFFSETS[s] == FloorPlan.START_CELL:
			side = s
	var dir := DungeonRoom.side_direction(side)
	var g := arena.gladiator
	_teleport_player(room.door_position(side) - dir * 4.0, room)
	var away := atan2(dir.x, dir.z)   # вперёд = -dir, прочь от двери
	g.global_rotation.y = away
	g.intent_facing_yaw = away
	# Камера тоже смотрит назад: игрок глядит на комнату, от которой отходит.
	game.get_node("CameraRig").call("snap_behind_target")
	await _frames(2)
	r.ge(_flat_forward(g).dot(-dir), 0.9, "вход спиной: до перехода игрок смотрит прочь от двери")
	r.ge(_camera_forward().dot(-dir), 0.9, "вход спиной: до перехода камера смотрит прочь от двери")

	var before := _entries.size()
	_face = -dir
	_walk = dir
	_stop_on_entry = true
	var n := 0
	while n < WALK_FRAMES and _entries.size() == before:
		await get_tree().physics_frame
		n += 1
	_stop_on_entry = false
	_stop()
	await _frames(10)
	var made := _entries.size() - before
	r.eq(made, 1, "вход спиной: ровно один переход")
	if made < 1:
		_recover_to_start()
		await _frames(5)
		return
	var e: Dictionary = _entries[before]
	_check_entry(e, fl.current_cell, int(e["from"]), "вход спиной")
	var inward := -DungeonRoom.side_direction(int(e["from"]))
	r.ge(_flat_forward(g).dot(inward), FACING_MIN_DOT,
		"вход спиной: через 10 кадров тело игрока смотрит в комнату")
	r.ge(_camera_forward().dot(inward), FACING_MIN_DOT,
		"вход спиной: через 10 кадров камера смотрит в комнату")


## Дополнение 1: набор, из которого не заспавнился никто (пул исчерпан), не
## должен запирать комнату и обязан засчитать её зачищенной.
func _check_empty_encounter(run: RunState, fl: DungeonFloor, plan: FloorPlan) -> void:
	var cell := Vector2i(-1, -1)
	var side := -1
	var cells: Array = plan.rooms.keys()
	cells.sort()
	for c in cells:
		if int(plan.spec(c)["type"]) != FloorPlan.RoomType.COMBAT or run.is_cleared(c):
			continue
		var doors := plan.doors_of(c)
		for s in doors.keys():
			if int(doors[s]) != FloorPlan.DoorState.LOCKED_BY_KEY:
				cell = c
				side = s
				break
		if side >= 0:
			break
	r.check(side >= 0, "пустой набор: нашлась незачищенная боевая комната")
	if side < 0:
		return

	var saved: Array[Zombie] = arena._pool
	var empty: Array[Zombie] = []
	arena._pool = empty
	var signals_before: int = _cleared_signals[0]
	var cleared_before := run.cleared.size()
	runner.enter_cell(cell, side)
	r.eq(arena.get_alive_count(), 0, "пустой набор: никто не заспавнился")
	await _frames(5)
	r.eq(_cleared_signals[0] - signals_before, 1, "пустой набор: encounter_cleared всё равно пришёл")
	r.check(run.is_cleared(cell), "пустой набор: комната засчитана зачищенной")
	r.eq(run.cleared.size() - cleared_before, 1, "пустой набор: одна отметка зачистки")
	_check_doors_expected(false, "пустой набор")
	_check_door_sync("пустой набор")
	await _frames(30)
	r.eq(_cleared_signals[0] - signals_before, 1, "пустой набор: сигнал не повторился")
	arena._pool = saved


## Точки входа у КАЖДОГО контура и каждой стороны: на полу с запасом под
## капсулу и стену, поперёк стороны входа, в стороне от порога. Проход по
## этажу видит только контуры своего сида - именно так Г-образная стартовая
## комната на входе с севера и запада и уходила в аварийную расстановку.
func _check_entry_spots_all_shapes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var all_doors := {
		0: FloorPlan.DoorState.OPEN, 1: FloorPlan.DoorState.OPEN,
		2: FloorPlan.DoorState.OPEN, 3: FloorPlan.DoorState.OPEN,
	}
	for shape in RoomGenerator.SHAPES:
		var cfg := RoomGenerator.geometry(rng)
		cfg["shape"] = shape
		var room := DungeonRoom.new()
		add_child(room)
		room.setup(cfg, Vector3(-400.0, 0.0, -400.0), all_doors, false)
		for side in [-1, 0, 1, 2, 3]:
			var label := "точки входа: %s, сторона %d" % [shape, side]
			var spots: Array = FloorRunner.entry_spots(room, side)
			r.eq(spots.size(), 2, label + ": две точки")
			if spots.size() != 2:
				continue
			var a: Vector3 = spots[0]
			var b: Vector3 = spots[1]
			r.check(room.has_floor_at(a, FLOOR_CLEARANCE) and room.has_floor_at(b, FLOOR_CLEARANCE),
				label + ": обе на полу, не в стене")
			var sep := b - a
			sep.y = 0.0
			r.ge(sep.length(), 1.0, label + ": бойцы не друг в друге, м")
			if side < 0:
				continue
			r.in_range(absf(sep.normalized().dot(DungeonRoom.side_direction(side))), 0.0, 0.05,
				label + ": поперёк стороны входа")
			var door := room.door_position(side)
			r.ge(minf(_flat_distance(a, door), _flat_distance(b, door)), DOOR_REACH + 0.5,
				label + ": в стороне от порога, м")
		room.queue_free()
	await _frames(1)


## Нигде не было двух переходов в соседних кадрах - мгновенный возврат через
## ту же дверь выглядел бы именно так.
func _check_no_quick_bounce() -> void:
	for i in range(1, _entries.size()):
		var gap: int = int(_entries[i]["frame"]) - int(_entries[i - 1]["frame"])
		r.check(gap > 1, "переходы %d и %d не в соседних кадрах (разрыв %d)" % [i - 1, i, gap])


# ------------------------------------------------------------------
# Помощники
# ------------------------------------------------------------------

func _on_room_entered(cell: Vector2i, from_side: int) -> void:
	var zs: Array = []
	for z in arena.get_alive_zombies():
		zs.append(z.global_position)
	var ally := arena.ally
	_entries.append({
		"cell": cell,
		"from": from_side,
		"frame": Engine.get_process_frames(),
		"room": runner.current_room(),
		"player": arena.gladiator.global_position,
		"ally": ally.global_position if ally != null else Vector3.INF,
		"player_fwd": _flat_forward(arena.gladiator),
		"ally_fwd": _flat_forward(ally) if ally != null else Vector3.ZERO,
		"player_health": arena.gladiator.health,
		"ally_downed": ally != null and ally.is_downed(),
		"zombies": zs,
		"entry": runner.entry_point(),
	})
	if _stop_on_entry:
		_face = Vector3.ZERO
		_stop()


## Ведёт игрока в проём стороны side текущей комнаты кадрами физики. Возвращает
## запись о переходе или пустой словарь, если перехода не было. Проверяет, что
## переход ровно один: после него игрок ещё полсекунды давит в ту же сторону -
## ровно так ходит человек, и именно здесь родился бы переход обратно.
func _walk_through(side: int, label: String) -> Dictionary:
	var room := _current_room()
	var dir := DungeonRoom.side_direction(side)
	var door := room.door_position(side)
	_teleport_player(door - dir * 4.0, room)
	await _frames(2)
	var before := _entries.size()
	_walk = dir
	var n := 0
	while n < WALK_FRAMES and _entries.size() == before:
		await get_tree().physics_frame
		n += 1
	await _frames(30)
	_stop()
	await _frames(3)
	var made := _entries.size() - before
	r.eq(made, 1, label + ": ровно один переход")
	if made < 1:
		return {}
	var e: Dictionary = _entries[before]
	if int(e["from"]) >= 0:
		# Камеру поворачивает только мышь, а в headless её нет: без разворота
		# при входе камера так и смотрела бы туда, куда при старте этажа.
		var inward := -DungeonRoom.side_direction(int(e["from"]))
		r.ge(_flat_forward(arena.gladiator).dot(inward), FACING_MIN_DOT,
			label + ": спустя кадры тело игрока смотрит в комнату")
		r.ge(_camera_forward().dot(inward), FACING_MIN_DOT,
			label + ": спустя кадры камера смотрит в комнату")
	return e


func _check_entry(e: Dictionary, cell: Vector2i, from_side: int, label: String) -> void:
	r.eq(e["cell"], cell, label + ": клетка перехода")
	r.eq(e["from"], from_side, label + ": сторона входа")
	var room: DungeonRoom = e["room"]
	if room == null:
		r.check(false, label + ": комната перехода существует")
		return
	var p: Vector3 = e["player"]
	r.check(room.has_floor_at(p, FLOOR_CLEARANCE), label + ": игрок приземлился на пол, не в стену")
	r.in_range(p.y - room.global_position.y, -0.05, 0.3, label + ": игрок на высоте пола")
	var a: Vector3 = e["ally"]
	if a != Vector3.INF:
		r.check(room.has_floor_at(a, FLOOR_CLEARANCE), label + ": напарник приземлился на пол, не в стену")
		var sep := a - p
		sep.y = 0.0
		r.ge(sep.length(), 1.0, label + ": бойцы не друг в друге, м")
		if from_side >= 0 and sep.length() > 0.001:
			var normal := DungeonRoom.side_direction(from_side)
			r.in_range(absf(sep.normalized().dot(normal)), 0.0, 0.05,
				label + ": бойцы стоят поперёк стороны входа")
	if from_side >= 0:
		var door := room.door_position(from_side)
		for q in [p, a]:
			if q == Vector3.INF:
				continue
			r.ge(_flat_distance(q, door), DOOR_REACH + 0.5, label + ": боец в стороне от порога, м")
		# В кадре входа, а не спустя время: у напарника дальше поворотом
		# управляет политика, и развернуть его обязан сам вход.
		var inward := -DungeonRoom.side_direction(from_side)
		var pf: Vector3 = e["player_fwd"]
		r.ge(pf.dot(inward), FACING_MIN_DOT, label + ": игрок сразу развёрнут в комнату")
		if a != Vector3.INF:
			var af: Vector3 = e["ally_fwd"]
			r.ge(af.dot(inward), FACING_MIN_DOT, label + ": напарник сразу развёрнут в комнату")


func _expected_state(planned: int, fight: bool) -> int:
	if planned == FloorPlan.DoorState.LOCKED_BY_KEY:
		return planned
	# Открытая дверь и треснувшая стена (в срезе 1 секретка доступна как
	# обычный тупик) одинаково запираются боем.
	return FloorPlan.DoorState.LOCKED_BY_FIGHT if fight else FloorPlan.DoorState.OPEN


func _check_doors_expected(fight: bool, label: String) -> void:
	var fl := runner.dungeon()
	var plan := runner.plan()
	var room := fl.current_room()
	var doors := plan.doors_of(fl.current_cell)
	for side in doors.keys():
		r.eq(room.door_state(side), _expected_state(int(doors[side]), fight),
			"%s: состояние двери %d" % [label, side])


## Общая дверь согласована с обеих сторон: у соседней комнаты своя коллизия-
## блокиратор на той же стене, и её устаревшее состояние заперло бы проход.
func _check_door_sync(label: String) -> void:
	var fl := runner.dungeon()
	var plan := runner.plan()
	var cell := fl.current_cell
	var room := fl.current_room()
	for side in plan.doors_of(cell).keys():
		var other := fl.built_room(cell + FloorPlan.SIDE_OFFSETS[side])
		r.check(other != null, "%s: сосед за дверью %d построен" % [label, side])
		if other == null:
			continue
		var back := FloorPlan.opposite_side(side)
		r.eq(other.door_state(back), room.door_state(side),
			"%s: дверь %d совпадает с обратной стороной" % [label, side])
		var a: CollisionShape3D = room._blockers.get(side)
		var b: CollisionShape3D = other._blockers.get(back)
		r.check(a != null and b != null, "%s: блокираторы двери %d есть с обеих сторон" % [label, side])
		if a == null or b == null:
			continue
		var open := room.door_state(side) == FloorPlan.DoorState.OPEN
		r.eq(a.disabled, open, "%s: блокиратор двери %d по состоянию" % [label, side])
		r.eq(b.disabled, open, "%s: блокиратор обратной стороны двери %d по состоянию" % [label, side])


func _current_room() -> DungeonRoom:
	return runner.current_room()


func _teleport_player(at: Vector3, room: DungeonRoom) -> void:
	var g := arena.gladiator
	g.velocity = Vector3.ZERO
	g.global_position = Vector3(at.x, room.global_position.y + 0.05, at.z)


func _stop() -> void:
	_walk = Vector3.ZERO
	arena.gladiator.intent_move_world = Vector3.ZERO


## Если переход не случился, сценарий не должен сыпаться каскадом ложных
## провалов: возвращаем бойцов в стартовую клетку напрямую.
func _recover_to_start() -> void:
	if runner.current_cell() != FloorPlan.START_CELL:
		runner.enter_cell(FloorPlan.START_CELL, -1)


func _heal_team() -> void:
	for f in arena.get_fighters():
		if f.is_downed():
			f.revive()
		if f.is_alive():
			f.health = f.max_health


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


## Ближайший зомби к двери входа, точке входа и бойцам в момент перехода.
func _nearest_zombie(e: Dictionary) -> float:
	var room: DungeonRoom = e["room"]
	var points: Array = [e["entry"], e["player"], e["ally"]]
	if int(e["from"]) >= 0:
		points.append(room.door_position(int(e["from"])))
	var nearest := INF
	for z in e["zombies"]:
		for p in points:
			if p != Vector3.INF:
				nearest = minf(nearest, _flat_distance(z, p))
	return nearest


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Вперёд по горизонтали, единичный вектор.
func _flat_forward(n: Node3D) -> Vector3:
	var f := -n.global_basis.z
	f.y = 0.0
	return f.normalized()


func _camera_forward() -> Vector3:
	return _flat_forward(_cam) if _cam != null else Vector3.ZERO

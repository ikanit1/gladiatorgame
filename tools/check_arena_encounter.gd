extends SceneTree

## Поведенческая проверка боя-за-комнату: encounter_driven, spawn_encounter,
## encounter_cleared, clear_room и старая тестовая коробка арены.
##
## План задачи 8 проверяет только парсинг и check_variants (путь обучения).
## До задачи 13 (GameScreen) это единственная проверка, что связка
## encounter_driven/spawn_encounter/clear_room реально работает в игре -
## а задача 13 целиком на неё опирается.

const SPEC_VARIANTS := [
	Zombie.Variant.NORMAL, Zombie.Variant.RUNNER, Zombie.Variant.BRUTE,
	Zombie.Variant.NORMAL, Zombie.Variant.RUNNER,
]


func _initialize() -> void:
	# Поля Arena нужно выставить ДО add_child - _ready() читает их сразу же.
	# _init() SceneTree слишком раннее место для await, поэтому откладываем.
	call_deferred("run_checks")


func run_checks() -> void:
	var r := TestReport.new("ArenaEncounter")

	await _check_game_mode_does_not_self_start(r)
	await _check_spawn_encounter_places_inside_room(r)
	await _check_encounter_cleared_once(r)
	await _check_clear_room(r)
	await _check_training_path_still_infinite(r)
	await _check_training_box_hidden_only_when_encounter_driven(r)

	r.finish(self)


# ------------------------------------------------------------------
# Помощники
# ------------------------------------------------------------------

## Поднимает Arena.tscn с полями, выставленными до add_child. Без напарника
## (ally_enabled = false) не нужна ONNX-политика - её отсутствие в headless-
## окружении не должно быть условием прохождения этой проверки.
func _make_arena(encounter_driven: bool, waves_in_room: int = 0) -> Arena:
	var arena: Arena = load("res://scenes/Arena.tscn").instantiate()
	arena.human_control = false
	arena.visuals_enabled = false
	arena.ally_enabled = false
	arena.encounter_driven = encounter_driven
	arena.waves_in_room = waves_in_room
	arena.auto_reset = false
	root.add_child(arena)
	return arena


func _make_room(rng: RandomNumberGenerator, center: Vector3) -> DungeonRoom:
	var cfg := RoomGenerator.geometry(rng)
	var room := DungeonRoom.new()
	root.add_child(room)
	room.setup(cfg, center, {}, false)
	return room


func _five_specs() -> Array:
	var specs: Array = []
	for v in SPEC_VARIANTS:
		specs.append({
			"variant": v,
			"health_scale": 1.3,
			"speed_scale": 1.1,
			"damage_scale": 1.4,
			"cooldown_scale": 0.85,
		})
	return specs


# ------------------------------------------------------------------
# Проверки
# ------------------------------------------------------------------

## Игра (encounter_driven = true) не должна сама выдумывать волны: после
## отложенного reset_arena из _ready() и нескольких кадров живых зомби ноль.
func _check_game_mode_does_not_self_start(r: TestReport) -> void:
	var arena := _make_arena(true)
	await physics_frame
	await physics_frame
	await physics_frame

	r.eq(arena.get_alive_count(), 0,
		"encounter_driven: арена не стартует бой сама")

	arena.queue_free()
	await physics_frame


## spawn_encounter ставит ровно набор specs, каждый зомби - внутри combat_room,
## и набор вариантов зомби совпадает с набором из specs.
func _check_spawn_encounter_places_inside_room(r: TestReport) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 555
	var arena := _make_arena(true)
	await physics_frame
	await physics_frame

	# Комната заметно смещена от начала координат - именно так на этаже и
	# будет: комнаты стоят в мировой сетке, а не вокруг (0,0,0).
	var center := Vector3(120.0, 0.0, -80.0)
	var room := _make_room(rng, center)
	arena.combat_room = room

	var specs := _five_specs()
	arena.spawn_encounter(specs)

	var alive := arena.get_alive_zombies()
	r.eq(alive.size(), 5, "spawn_encounter: живых ровно 5")

	var half := room.get_half_extents()
	for i in alive.size():
		var z: Zombie = alive[i]
		r.check(absf(z.global_position.x - center.x) <= half.x + 0.01,
			"зомби %d внутри комнаты по x" % i)
		r.check(absf(z.global_position.z - center.z) <= half.z + 0.01,
			"зомби %d внутри комнаты по z" % i)

	var expected_counts := {}
	for spec in specs:
		var v: int = int(spec["variant"])
		expected_counts[v] = int(expected_counts.get(v, 0)) + 1
	var actual_counts := {}
	for z in alive:
		actual_counts[z.variant] = int(actual_counts.get(z.variant, 0)) + 1
	r.eq(actual_counts, expected_counts,
		"variant каждого зомби совпадает с набором из specs")

	arena.queue_free()
	room.queue_free()
	await physics_frame


## Когда набор выбит весь, encounter_cleared эмитится РОВНО один раз, и после
## этого арена не запускает новую волну сама сколько угодно кадров подряд.
func _check_encounter_cleared_once(r: TestReport) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 999
	var arena := _make_arena(true)
	await physics_frame
	await physics_frame

	var room := _make_room(rng, Vector3(-60.0, 0.0, 30.0))
	arena.combat_room = room
	arena.spawn_encounter(_five_specs())

	# Массив, а не int: лямбда в GDScript захватывает локальные переменные ПО
	# ЗНАЧЕНИЮ, а не по ссылке - cleared_count += 1 внутри замыкания менял бы
	# копию и снаружи так и остался бы 0. Массив захватывается той же ссылкой
	# на объект, поэтому мутация его содержимого видна и здесь.
	var cleared_count := [0]
	arena.encounter_cleared.connect(func() -> void: cleared_count[0] += 1)

	# Урон через боевой API зомби, как в настоящем бою.
	for z in arena.get_alive_zombies():
		z.take_damage(100000.0, z.global_position + Vector3(1.0, 0.0, 0.0))

	r.eq(arena.get_alive_count(), 0, "все зомби набора убиты")

	for i in 5:
		await physics_frame
	r.eq(cleared_count[0], 1, "encounter_cleared испущен ровно один раз")

	for i in 40:
		await physics_frame
	r.eq(cleared_count[0], 1, "encounter_cleared не переиспускается")
	r.eq(arena.get_alive_count(), 0,
		"после очистки набора новая волна не началась сама")

	arena.queue_free()
	room.queue_free()
	await physics_frame


## clear_room готовит арену к бою в другой комнате: гасит живых и доживающих
## (retiring) зомби, но НЕ трогает здоровье бойца - см. Task 8 плана про
## бесплатный подъём напарника на каждом переходе в дверь.
func _check_clear_room(r: TestReport) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var arena := _make_arena(true)
	await physics_frame
	await physics_frame

	arena.gladiator.health = 37.0

	var room := _make_room(rng, Vector3(40.0, 0.0, 200.0))
	arena.combat_room = room
	arena.spawn_encounter(_five_specs())

	var alive := arena.get_alive_zombies()
	r.eq(alive.size(), 5, "перед очисткой комнаты живых 5")

	# Один зомби переводим в "доживает анимацию смерти" напрямую - это то же
	# состояние, в которое зомби попадает через _on_zombie_died при
	# visuals_enabled = true (см. Дополнение 2 задания). clear_room обязана
	# погасить и такого зомби, а не только is_alive().
	alive[0].state = Zombie.State.DEAD
	alive[0].retire_with_animation()
	r.check(alive[0].retiring and not alive[0].is_alive(),
		"подготовка: один зомби переведён в retiring вручную")

	arena.clear_room()

	r.eq(arena.get_alive_count(), 0, "clear_room: живых ноль")
	var still_retiring := 0
	for z in arena._pool:
		if z.retiring:
			still_retiring += 1
	r.eq(still_retiring, 0, "clear_room: доживающих не осталось")
	r.eq(arena.gladiator.health, 37.0, "clear_room: здоровье бойца не изменилось")

	arena.queue_free()
	room.queue_free()
	await physics_frame


## Путь обучения: encounter_driven = false, waves_in_room = 0 - бесконечная
## арена обязана запускать волну сама, как и раньше. Это защита от регресса:
## обученная политика напарника иначе окажется в другом мире, чем училась.
func _check_training_path_still_infinite(r: TestReport) -> void:
	var arena := _make_arena(false, 0)

	for i in 5:
		await physics_frame

	r.check(arena.get_alive_count() > 0,
		"путь обучения: encounter_driven=false запускает волну сама")

	arena.queue_free()
	await physics_frame


## Дополнение 1: старая тестовая коробка арены (Environment, Decor) прячется
## ТОЛЬКО в режиме encounter_driven = true. В обучении (encounter_driven =
## false) эта коробка и есть арена - её трогать нельзя.
func _check_training_box_hidden_only_when_encounter_driven(r: TestReport) -> void:
	var driven := _make_arena(true)
	var training := _make_arena(false, 0)

	# set_deferred("disabled", ...) применяется в конце кадра - ждём кадр.
	await physics_frame
	await physics_frame

	var driven_env: Node3D = driven.get_node("Environment")
	r.eq(driven_env.visible, false, "encounter_driven=true: Environment скрыт")
	for child in driven_env.get_children():
		if child is CollisionShape3D:
			r.eq((child as CollisionShape3D).disabled, true,
				"encounter_driven=true: коллизия %s отключена" % child.name)

	var training_env: Node3D = training.get_node("Environment")
	r.eq(training_env.visible, true, "encounter_driven=false: Environment виден")
	for child in training_env.get_children():
		if child is CollisionShape3D:
			r.eq((child as CollisionShape3D).disabled, false,
				"encounter_driven=false: коллизия %s включена" % child.name)

	driven.queue_free()
	training.queue_free()
	await physics_frame

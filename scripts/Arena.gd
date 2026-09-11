class_name Arena
extends Node3D

## Одна арена = одно окружение (env) для обучения.
##
## Сцена спроектирована так, чтобы её можно было инстансировать N раз в одной
## сцене верхнего уровня (сетка арен) - никаких обращений к глобальным группам,
## всё через локальные ссылки и относительные координаты.

signal wave_started(wave_index: int, count: int)
signal zombie_killed(total_kills: int)
signal episode_ended(reason: String)
signal potion_spawned(potion: Potion)
signal potion_taken(healed: float)
signal fighter_downed(fighter: Gladiator)
signal fighter_revived(fighter: Gladiator)
signal wave_cleared(wave_index: int)
## Набор врагов от spawn_encounter выбит подчистую. Аналог wave_cleared для
## режима encounter_driven - там комната это один бой, а не серия волн.
signal encounter_cleared()

@export_group("Волны")
@export var zombie_scene: PackedScene
@export var pool_size: int = 24            ## размер пула; должен быть >= max_alive
@export var first_wave_size: int = 2
@export var wave_growth: int = 1           ## насколько растёт волна
@export var max_alive: int = 8
@export var wave_delay: float = 2.0

@export_group("Зелья")
@export var potion_scene: PackedScene
@export var potion_pool_size: int = 6
@export var max_potions: int = 3           ## сколько лежит на арене одновременно
@export var potion_interval: float = 8.0   ## пауза между появлениями
@export var potion_pickup_radius: float = 1.3
@export var potion_spawn_radius: float = 8.5
@export var potion_heal: float = 30.0

@export_group("Спавн")
@export var spawn_radius: float = 9.0
@export var min_spawn_distance: float = 5.0   ## не спавнить зомби вплотную к игроку

@export_group("Союзник (кооператив)")
## Второй гладиатор под управлением обученной политики, играющий на стороне
## человека. Наблюдения агента при этом НЕ меняются: он видит зомби, стены
## и зелья, но не напарника. Иначе пришлось бы переобучать модель.
@export var ally_enabled: bool = false
@export var gladiator_scene: PackedScene
@export_file("*.policy") var ally_policy: String = "res://models/gladiator_team_v5.policy"
## false - напарник ждёт внешнего управления (AIController при обучении),
## LocalAgent к нему не цепляется.
@export var ally_local_policy: bool = true
@export var ally_offset: Vector3 = Vector3(2.5, 0.0, 0.5)

@export_group("Комната")
## Сколько волн отбить, прежде чем откроется выход. 0 - бесконечная арена
## (так работает обучение).
@export var waves_in_room: int = 0
## true - волны не генерируются вовсе, набор врагов приходит снаружи через
## spawn_encounter. Так работает игра: комната это один бой, а не серия волн.
## В обучении флаг остаётся false, и старый бесконечный режим не меняется.
@export var encounter_driven: bool = false

@export_group("Разновидности зомби")
## Бегуны и громилы. Политика с версии gladiator_team_v5 обучена против всех
## трёх типов и видит тип ближайшего врага в наблюдениях, так что включать
## их безопасно. По умолчанию false ради сцен-заглушек и ручной отладки;
## игра и обучение выставляют флаг явно.
@export var variants_enabled: bool = false
@export var runner_from_wave: int = 3
@export var brute_from_wave: int = 5

@export_group("Подъём напарника")
## Поверженный боец лежит и ждёт помощи вместо мгновенной смерти.
## В обучении выключено: лишнее состояние размыло бы границы эпизода.
@export var revive_enabled: bool = false
@export var revive_radius: float = 2.2
@export var revive_duration: float = 2.5
@export var downed_timeout: float = 25.0
@export var revive_health: float = 45.0

@export_group("Режим")
@export var human_control: bool = true     ## false - управление отдаётся AIController
@export var visuals_enabled: bool = true   ## false при обучении: гасит модели, декор и факелы
@export var auto_reset: bool = true        ## перезапуск после смерти (для ручной отладки)
@export var arena_seed: int = 0            ## 0 = случайный сид

@onready var gladiator: Gladiator = $Gladiator
@onready var zombie_root: Node3D = $Zombies

var ally: Gladiator = null           ## напарник под управлением политики
var ally_status: String = ""         ## почему напарник не появился, если не появился

var wave_index: int = 0
## Номер волны за весь забег. wave_index сбрасывается в каждой комнате,
## а этот счётчик нужен для бесконечного роста угрозы.
var run_wave_index: int = 0
var total_kills: int = 0

var _pool: Array[Zombie] = []
var _potions: Array[Potion] = []
var _potion_timer: float = 0.0
var _alive_count: int = 0
var _wave_timer: float = 0.0
var _rng := RandomNumberGenerator.new()
var _spawn_origin: Transform3D
var _reset_pending: bool = false
var _started: bool = false
var _ally_origin: Transform3D
var _retarget_timer: float = 0.0
var _last_reset_frame: int = -1
var revive_progress: float = 0.0     ## 0..1, для полосы в HUD
var revive_target: Gladiator = null
var _wave_live: bool = false

## Комната, в которой идёт текущий бой. Ставится снаружи (DungeonFloor).
## Нужна только для выбора точек спавна: Arena про этажи ничего не знает.
var combat_room: DungeonRoom = null

# Формы и меши приходят из .tscn общими ресурсами. Если менять их напрямую,
# размер поменяется у ВСЕХ арен сразу - при обучении это 16 одновременно
# перестроенных окружений. Поэтому у каждой арены свои копии.
var _own_res: Dictionary = {}


func _ready() -> void:
	if arena_seed != 0:
		_rng.seed = arena_seed
	else:
		_rng.randomize()

	_spawn_origin = gladiator.global_transform

	# Ручной ввод отключаем целиком, а не удаляем - чтобы одна и та же сцена
	# годилась и для отладки, и для headless-обучения.
	var input_node := gladiator.get_node_or_null("PlayerInput")
	if input_node != null:
		input_node.process_mode = Node.PROCESS_MODE_INHERIT if human_control else Node.PROCESS_MODE_DISABLED

	_clone_room_resources()
	_build_pool()
	_build_potions()
	_setup_revive(gladiator)
	if ally_enabled:
		_spawn_ally()
	gladiator.died.connect(_on_gladiator_died)

	if not visuals_enabled:
		_disable_visuals()

	# Только в игре: комнаты строит DungeonFloor снаружи, и старая тестовая
	# коробка арены (стены/пол/факелы из .tscn) осталась бы жить в начале
	# координат совсем не там, где стоит настоящий этаж. В обучении
	# (encounter_driven == false) эта коробка и есть арена - трогать нельзя.
	if encounter_driven:
		_hide_training_box()

	# Первый сброс - отложенно: даём физическому серверу применить
	# позиции только что созданного пула до первого шага симуляции.
	reset_arena.call_deferred()


func _physics_process(delta: float) -> void:
	if not _started or not any_fighter_alive():
		return

	_update_potions(delta)
	_update_zombie_targets(delta)
	if revive_enabled:
		_update_revive(delta)

	if _alive_count > 0:
		return

	if encounter_driven:
		# Набор кончился - сообщаем наружу один раз и ждём следующего.
		if _wave_live:
			_wave_live = false
			encounter_cleared.emit()
		return

	if _wave_live:
		_wave_live = false
		wave_cleared.emit(wave_index)
	_wave_timer -= delta
	if _wave_timer <= 0.0:
		_start_next_wave()


func _unhandled_input(event: InputEvent) -> void:
	if human_control and event.is_action_pressed("g_reset"):
		reset_arena()


# ------------------------------------------------------------------
# Пул зомби
# ------------------------------------------------------------------

func _build_pool() -> void:
	if zombie_scene == null:
		push_error("Arena: не задана zombie_scene")
		return

	for i in pool_size:
		var z: Zombie = zombie_scene.instantiate()
		# ПОДВОХ: позицию надо задать ДО add_child. Иначе тело на один кадр
		# появляется в (0,0,0) - ровно там, где стоит гладиатор, - и физический
		# сервер успевает зарегистрировать глубокое пересечение. Гладиатора
		# выбрасывает из него со скоростью в сотни м/с прямо в стену.
		z.position = Vector3(0.0, -100.0, 0.0)
		zombie_root.add_child(z)
		z.died.connect(_on_zombie_died)
		z.deactivate()
		_pool.append(z)


## Гасит всю визуальную ветку. Модели, анимация и факелы не участвуют
## в физике и наблюдениях, поэтому при headless-обучении это чистая экономия.
func _disable_visuals() -> void:
	var decor := get_node_or_null("Decor")
	if decor != null:
		decor.process_mode = Node.PROCESS_MODE_DISABLED
		decor.visible = false

	var combat_fx := get_node_or_null("CombatFX")
	if combat_fx != null:
		combat_fx.process_mode = Node.PROCESS_MODE_DISABLED
		combat_fx.visible = false

	_hide_visuals_of(gladiator)
	for z in _pool:
		_hide_visuals_of(z)
	# Зелья - целиком визуал плюс позиция; гасим только отрисовку,
	# сама механика подбора обязана работать и при обучении.
	for p in _potions:
		p.visible = false
		p.set_process(false)


func _hide_visuals_of(body: Node) -> void:
	var v := body.get_node_or_null("Visuals")
	if v != null:
		v.process_mode = Node.PROCESS_MODE_DISABLED
		v.visible = false


func _get_free_zombie() -> Zombie:
	for z in _pool:
		if not z.is_alive() and not z.retiring:
			return z
	# Reuse a corpse if the pool is full rather than delaying a scheduled spawn.
	for z in _pool:
		if z.retiring:
			return z
	return null   # пул исчерпан - молча пропускаем спавн


# ------------------------------------------------------------------
# Союзник
# ------------------------------------------------------------------

func _spawn_ally() -> void:
	if gladiator_scene == null:
		ally_status = "не задана gladiator_scene"
		push_warning("Arena: " + ally_status)
		return

	var a: Gladiator = gladiator_scene.instantiate()
	# Позицию задаём ДО add_child - тот же урок, что и с пулом зомби:
	# иначе тело на кадр появляется в (0,0,0) поверх игрока.
	a.position = ally_offset
	add_child(a)
	ally = a
	_ally_origin = a.transform
	_setup_revive(a)

	var input_node := a.get_node_or_null("PlayerInput")
	if input_node != null:
		input_node.process_mode = Node.PROCESS_MODE_DISABLED

	if ally_local_policy:
		var agent := LocalAgent.new()
		agent.name = "LocalAgent"
		agent.policy_path = ally_policy
		a.add_child(agent)
		ally_status = agent.status
	else:
		ally_status = "внешнее управление"
	a.died.connect(_on_gladiator_died)


## Все живые бойцы на стороне игрока.
func get_fighters() -> Array[Gladiator]:
	var out: Array[Gladiator] = [gladiator]
	if ally != null:
		out.append(ally)
	return out


func any_fighter_alive() -> bool:
	for f in get_fighters():
		if f.is_alive():
			return true
	return false


func closest_fighter_to(pos: Vector3) -> Gladiator:
	var best: Gladiator = null
	var best_d := INF
	for f in get_fighters():
		if not f.is_alive():
			continue
		var d: float = f.global_position.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = f
	return best


## Зомби переключаются на ближайшего живого бойца. Пересчитываем не каждый
## кадр: цель, скачущая между двумя гладиаторами, заставляла бы зомби топтаться
## ровно посередине между ними.
func _update_zombie_targets(delta: float) -> void:
	if ally == null:
		return

	_retarget_timer -= delta
	if _retarget_timer > 0.0:
		return
	_retarget_timer = 0.4

	for z in _pool:
		if not z.is_alive():
			continue
		var t := closest_fighter_to(z.global_position)
		if t != null:
			z.target = t



# ------------------------------------------------------------------
# Комната: размеры и выход
# ------------------------------------------------------------------

func _clone_room_resources() -> void:
	for path in ["Environment/FloorShape", "Environment/WallNorth", "Environment/WallSouth",
			"Environment/WallEast", "Environment/WallWest"]:
		var n := get_node_or_null(path) as CollisionShape3D
		if n != null and n.shape != null:
			n.shape = n.shape.duplicate()
			_own_res[path] = n.shape

	for path in ["Decor/Floor", "Decor/WallNorth", "Decor/WallSouth",
			"Decor/WallEast", "Decor/WallWest"]:
		var m := get_node_or_null(path) as MeshInstance3D
		if m != null and m.mesh != null:
			m.mesh = m.mesh.duplicate()
			_own_res[path] = m.mesh


## Перестраивает арену под новый размер. Вызывается при входе в комнату.
func set_room_size(w: float, d: float) -> void:
	var hw := w * 0.5
	var hd := d * 0.5

	_shape_size("Environment/FloorShape", Vector3(w, 0.5, d), Vector3(0, -0.25, 0))
	_shape_size("Environment/WallNorth", Vector3(w + 2.0, 3.0, 1.0), Vector3(0, 1.5, -hd - 0.5))
	_shape_size("Environment/WallSouth", Vector3(w + 2.0, 3.0, 1.0), Vector3(0, 1.5, hd + 0.5))
	_shape_size("Environment/WallEast", Vector3(1.0, 3.0, d + 2.0), Vector3(hw + 0.5, 1.5, 0))
	_shape_size("Environment/WallWest", Vector3(1.0, 3.0, d + 2.0), Vector3(-hw - 0.5, 1.5, 0))

	_plane_size("Decor/Floor", Vector2(w + 2.0, d + 2.0), Vector3.ZERO)
	_box_size("Decor/WallNorth", Vector3(w + 2.0, 3.0, 1.0), Vector3(0, 1.5, -hd - 0.5))
	_box_size("Decor/WallSouth", Vector3(w + 2.0, 3.0, 1.0), Vector3(0, 1.5, hd + 0.5))
	_box_size("Decor/WallEast", Vector3(1.0, 3.0, d + 2.0), Vector3(hw + 0.5, 1.5, 0))
	_box_size("Decor/WallWest", Vector3(1.0, 3.0, d + 2.0), Vector3(-hw - 0.5, 1.5, 0))

	# Парапеты и колонны просто разносим по новым углам
	_move("Decor/CapNorth", Vector3(0, 3.17, -hd - 0.5))
	_move("Decor/CapSouth", Vector3(0, 3.17, hd + 0.5))
	_move("Decor/CapEast", Vector3(hw + 0.5, 3.17, 0))
	_move("Decor/CapWest", Vector3(-hw - 0.5, 3.17, 0))
	for corner in [["NE", 1.0, -1.0], ["NW", -1.0, -1.0], ["SE", 1.0, 1.0], ["SW", -1.0, 1.0]]:
		var sx: float = corner[1]
		var sz: float = corner[2]
		_move("Decor/Column" + corner[0], Vector3(sx * (hw + 0.5), 2.2, sz * (hd + 0.5)))
		_move("Decor/Capital" + corner[0], Vector3(sx * (hw + 0.5), 4.6, sz * (hd + 0.5)))
		_move("Decor/Torch" + corner[0], Vector3(sx * (hw + 0.5), 4.95, sz * (hd + 0.5)))

	# Спавн подстраиваем под меньшую сторону, иначе на вытянутой карте
	# зомби появлялись бы в стенах
	var half := minf(hw, hd)
	spawn_radius = maxf(4.0, half - 1.8)
	min_spawn_distance = minf(min_spawn_distance, spawn_radius * 0.7)
	potion_spawn_radius = maxf(3.0, half - 2.4)


func _shape_size(path: String, size: Vector3, pos: Vector3) -> void:
	var n := get_node_or_null(path) as CollisionShape3D
	if n == null:
		return
	var sh := n.shape as BoxShape3D
	if sh != null:
		sh.size = size
	n.position = pos


func _box_size(path: String, size: Vector3, pos: Vector3) -> void:
	var m := get_node_or_null(path) as MeshInstance3D
	if m == null:
		return
	var bm := m.mesh as BoxMesh
	if bm != null:
		bm.size = size
	m.position = pos


func _plane_size(path: String, size: Vector2, pos: Vector3) -> void:
	var m := get_node_or_null(path) as MeshInstance3D
	if m == null:
		return
	var pm := m.mesh as PlaneMesh
	if pm != null:
		pm.size = size
	m.position = pos


func _move(path: String, pos: Vector3) -> void:
	var n := get_node_or_null(path) as Node3D
	if n != null:
		n.position = pos


## Прячет старую тестовую коробку арены (Environment - стены и пол, Decor -
## факелы и декор). Она собрана прямо в Arena.tscn и раньше пряталась только
## при входе в первую процедурную комнату (_enable_dungeon_mode), которую
## строил сам Arena. Теперь комнаты строит снаружи DungeonFloor в СОВСЕМ
## других мировых координатах - если коробку не спрятать, она останется жить
## в начале координат ровно там, где раньше стоял игрок: со своими стенами,
## коллизиями и факелами поверх настоящего этажа.
##
## Только для encounter_driven: в обучении (encounter_driven == false) эта
## коробка и есть единственная арена, трогать её нельзя ни в коем случае.
func _hide_training_box() -> void:
	var environment := get_node_or_null("Environment")
	if environment != null:
		environment.visible = false
		for child in environment.get_children():
			if child is CollisionShape3D:
				(child as CollisionShape3D).set_deferred("disabled", true)

	var decor := get_node_or_null("Decor")
	if decor != null:
		decor.visible = false


# ------------------------------------------------------------------
# Подъём поверженного
# ------------------------------------------------------------------

func _setup_revive(f: Gladiator) -> void:
	f.downed_enabled = revive_enabled
	f.downed_timeout = downed_timeout
	f.revive_health = revive_health
	f.downed.connect(_on_fighter_downed.bind(f))
	f.revived.connect(_on_fighter_revived.bind(f))


func _on_fighter_downed(f: Gladiator) -> void:
	fighter_downed.emit(f)


func _on_fighter_revived(_hp: float, f: Gladiator) -> void:
	fighter_revived.emit(f)


func _update_revive(delta: float) -> void:
	var target := _find_downed()
	var rescuer := _find_rescuer(target)

	if target == null or rescuer == null:
		revive_progress = 0.0
		revive_target = null
		return

	revive_target = target
	revive_progress += delta / maxf(revive_duration, 0.05)
	if revive_progress >= 1.0:
		revive_progress = 0.0
		revive_target = null
		target.revive()


func _find_downed() -> Gladiator:
	for f in get_fighters():
		if f.is_downed():
			return f
	return null


## Кто поднимает. Игрок должен явно держать клавишу; ИИ-напарник поднимает
## сам, если оказался рядом - политика этому не обучена, и требовать от неё
## осознанного намерения было бы нечестно.
func _find_rescuer(target: Gladiator) -> Gladiator:
	if target == null:
		return null
	var r2 := revive_radius * revive_radius
	for f in get_fighters():
		if f == target or not f.is_alive():
			continue
		if f.global_position.distance_squared_to(target.global_position) > r2:
			continue
		if f == gladiator and not f.intent_revive:
			continue   # игрок поднимает только по нажатию
		return f
	return null


# ------------------------------------------------------------------
# Зелья
# ------------------------------------------------------------------

func _build_potions() -> void:
	if potion_scene == null:
		return
	var root := Node3D.new()
	root.name = "Potions"
	add_child(root)

	for i in potion_pool_size:
		var p: Potion = potion_scene.instantiate()
		p.position = Vector3(0.0, -100.0, 0.0)   # как и зомби: не появляться в (0,0,0)
		p.heal_amount = potion_heal
		root.add_child(p)
		p.deactivate()
		_potions.append(p)


func _update_potions(delta: float) -> void:
	if _potions.is_empty():
		return

	_potion_timer -= delta
	if _potion_timer <= 0.0 and get_active_potions().size() < max_potions:
		_spawn_potion()
		_potion_timer = potion_interval

	# Подбор - сравнение дистанций, без Area3D: см. комментарий в Potion.gd
	var r2 := potion_pickup_radius * potion_pickup_radius
	for p in _potions:
		if not p.is_active():
			continue
		for f in get_fighters():
			if not f.needs_healing():
				continue
			if p.global_position.distance_squared_to(f.global_position) > r2:
				continue
			var gained: float = f.heal(p.heal_amount)
			p.deactivate()
			potion_taken.emit(gained)
			return   # одно зелье за кадр - иначе одним рывком соберёт всё


func _spawn_potion() -> void:
	var free: Potion = null
	for p in _potions:
		if not p.is_active():
			free = p
			break
	if free == null:
		return

	var spawn_position: Vector3
	if combat_room != null:
		spawn_position = combat_room.get_random_floor_position(_rng)
	else:
		var angle := _rng.randf_range(0.0, TAU)
		var radius := _rng.randf_range(potion_spawn_radius * 0.25, potion_spawn_radius)
		spawn_position = to_global(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	free.activate(spawn_position)
	if visuals_enabled:
		free.visible = true
		free.set_process(true)
	potion_spawned.emit(free)


func get_active_potions() -> Array[Potion]:
	var out: Array[Potion] = []
	for p in _potions:
		if p.is_active():
			out.append(p)
	return out


# ------------------------------------------------------------------
# Волны
# ------------------------------------------------------------------

## Ставит готовый набор врагов. Каждый элемент specs - словарь:
##   variant: int (Zombie.Variant)
##   health_scale, speed_scale, damage_scale, cooldown_scale: float
##
## Позиции арена выбирает сама через _pick_spawn_transform: она знает про
## комнату и про минимальную дистанцию до бойцов, а вызывающий - нет.
func spawn_encounter(specs: Array) -> void:
	if not encounter_driven:
		push_warning("Arena.spawn_encounter вызван без encounter_driven")
	for spec in specs:
		var z := _get_free_zombie()
		if z == null:
			break
		var spawn := _pick_spawn_transform()
		var target := closest_fighter_to(spawn.origin)
		z.set_variant(int(spec.get("variant", Zombie.Variant.NORMAL)))
		z.set_threat_scaling(
			float(spec.get("health_scale", 1.0)),
			float(spec.get("speed_scale", 1.0)),
			float(spec.get("damage_scale", 1.0)),
			float(spec.get("cooldown_scale", 1.0)))
		z.activate(spawn, target if target != null else gladiator)
		_alive_count += 1

	_wave_live = _alive_count > 0
	wave_index += 1
	wave_started.emit(wave_index, specs.size())


func _start_next_wave() -> void:
	wave_index += 1
	run_wave_index += 1
	# После десятой волны рост не останавливается: добавляем врагов к лимиту
	# комнаты и усиливаем каждого. Это делает длинный забег рогаликом, а не
	# серией одинаковых слабых волн.
	var late_waves := maxi(0, run_wave_index - 10)
	var late_count_bonus := late_waves / 3
	var room_cap := mini(pool_size, max_alive + late_count_bonus)
	var count: int = mini(first_wave_size + (wave_index - 1) * wave_growth, room_cap)

	for i in count:
		_spawn_zombie()

	_wave_live = _alive_count > 0
	wave_started.emit(wave_index, count)


func _spawn_zombie() -> void:
	var z := _get_free_zombie()
	if z == null:
		return

	var spawn := _pick_spawn_transform()
	var target := closest_fighter_to(spawn.origin)
	z.set_variant(_pick_variant())
	z.set_threat_scaling(_zombie_health_scale(), _zombie_speed_scale(),
		_zombie_damage_scale(), _zombie_cooldown_scale())
	z.activate(spawn, target if target != null else gladiator)
	_alive_count += 1


func _zombie_health_scale() -> float:
	var late := float(maxi(0, run_wave_index - 10))
	return 1.0 + minf(0.16 * late + 0.012 * late * late, 4.0)


func _zombie_speed_scale() -> float:
	var late := float(maxi(0, run_wave_index - 10))
	return 1.0 + minf(0.018 * late, 0.42)


func _zombie_damage_scale() -> float:
	var late := float(maxi(0, run_wave_index - 10))
	return 1.0 + minf(0.075 * late + 0.003 * late * late, 1.8)


func _zombie_cooldown_scale() -> float:
	var late := float(maxi(0, run_wave_index - 10))
	return maxf(0.62, 1.0 - 0.012 * late)


## Чем дальше волна, тем разнообразнее враги. Первые волны намеренно
## однородные: иначе игрок не успевает понять базовые правила боя.
##
## ПОДВОХ: считать надо по run_wave_index - сквозному счётчику волн за
## забег, а не по wave_index, который сбрасывается в каждой комнате.
## Комната даёт 2-4 волны, порог громилы - пятая: с wave_index громилы
## не появлялись в игре ВООБЩЕ, а бегуны - только в последней волне
## четырёхволновой комнаты. Масштабирование угрозы рядом всегда считало
## по run_wave_index, так что расходились именно эти два порога.
func _pick_variant() -> int:
	if not variants_enabled:
		return Zombie.Variant.NORMAL

	var brute := 0.0
	if run_wave_index >= brute_from_wave:
		brute = minf(0.10 + 0.03 * float(run_wave_index - brute_from_wave), 0.30)
	var runner := 0.0
	if run_wave_index >= runner_from_wave:
		runner = minf(0.18 + 0.03 * float(run_wave_index - runner_from_wave), 0.38)

	var r := _rng.randf()
	if r < brute:
		return Zombie.Variant.BRUTE
	if r < brute + runner:
		return Zombie.Variant.RUNNER
	return Zombie.Variant.NORMAL


## Сила зелий меняется улучшением, а зелья лежат в пуле - обновляем все.
func set_potion_heal(value: float) -> void:
	potion_heal = value
	for p in _potions:
		p.heal_amount = value


func _pick_spawn_transform() -> Transform3D:
	var pos := Vector3.ZERO

	# До 8 попыток найти точку подальше от гладиатора. В данже берём
	# случайную клетку пола, а не круг вокруг начала сцены: комнаты могут быть
	# далеко друг от друга и иметь вырезанный или Г-образный контур.
	for attempt in 8:
		if combat_room != null:
			pos = combat_room.get_random_floor_position(_rng)
		else:
			var angle := _rng.randf_range(0.0, TAU)
			var radius := _rng.randf_range(spawn_radius * 0.7, spawn_radius)
			var local_pos := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			pos = to_global(local_pos)
		if pos.distance_to(gladiator.global_position) >= min_spawn_distance:
			break

	# Зомби смотрит на гладиатора
	var dir := gladiator.global_position - pos
	dir.y = 0.0
	var yaw := atan2(-dir.x, -dir.z) if dir.length_squared() > 0.0001 else 0.0

	# У капсулы зомби нижняя точка совпадает с origin CharacterBody3D:
	# Collision находится на y=0.8 и имеет высоту 1.6. Поэтому origin должен
	# быть ровно на уровне пола, без прежнего двойного подъёма на 0.1/0.2 м.
	var floor_y := global_position.y
	if combat_room != null:
		floor_y = combat_room.global_position.y
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(pos.x, floor_y, pos.z))


# ------------------------------------------------------------------
# Сигналы
# ------------------------------------------------------------------

func _on_zombie_died(z: Zombie) -> void:
	_alive_count = maxi(0, _alive_count - 1)
	total_kills += 1
	zombie_killed.emit(total_kills)

	# ПОДВОХ Godot: менять коллизии внутри физического шага нельзя.
	# deactivate() использует set_deferred, но саму деактивацию тоже
	# откладываем - тело успевает "дожить" текущий кадр.
	if visuals_enabled:
		z.retire_with_animation.call_deferred()
	else:
		z.deactivate.call_deferred()

	if _alive_count <= 0:
		_wave_timer = wave_delay


func _on_gladiator_died() -> void:
	# Бой продолжается, пока кто-то на ногах. Поверженный не считается:
	# поднять его будет некому.
	if any_fighter_alive():
		return
	episode_ended.emit("gladiator_died")
	if auto_reset and not _reset_pending:
		_reset_pending = true
		# Небольшая пауза, чтобы при ручной отладке было видно момент смерти
		get_tree().create_timer(1.5).timeout.connect(reset_arena)


# ------------------------------------------------------------------
# Сброс эпизода
# ------------------------------------------------------------------

## Полный сброс арены БЕЗ пересоздания нод.
## Это главный источник утечек памяти в RL-проектах на Godot: если на каждом
## эпизоде делать instantiate/queue_free, при миллионах шагов сцена деградирует.
func reset_arena(reset_position: bool = true, reset_run_stats: bool = true) -> void:
	# При обучении вдвоём оба агента увидят done в одном кадре и оба попросят
	# сброс. Второй вызов обнулил бы уже перезапущенную арену, и первый
	# эпизод после сброса вышел бы обрезанным.
	var frame := Engine.get_physics_frames()
	if frame == _last_reset_frame:
		return
	_last_reset_frame = frame

	for z in _pool:
		if z.is_alive() or z.retiring:
			z.deactivate()

	for p in _potions:
		p.deactivate()
	_potion_timer = potion_interval * 0.5   # первое зелье появляется раньше

	revive_progress = 0.0
	revive_target = null
	_wave_live = false
	_started = true
	_reset_pending = false
	_alive_count = 0
	wave_index = 0
	if reset_run_stats:
		total_kills = 0
		run_wave_index = 0
	_wave_timer = 0.0

	var current_player_transform := gladiator.global_transform
	if reset_position:
		current_player_transform = _spawn_origin
	gladiator.reset_state(current_player_transform)
	if ally != null:
		var ally_transform := global_transform * _ally_origin
		if not reset_position:
			ally_transform = ally.global_transform
		ally.reset_state(ally_transform)

	# В режиме encounter_driven набор врагов присылают снаружи: арена не
	# должна стартовать бой сама, иначе комната получит лишнюю волну.
	if not encounter_driven:
		_start_next_wave()


## Готовит арену к бою в другой комнате: гасит врагов и зелья, но бойцов НЕ
## трогает.
##
## Полный reset_arena здесь не годится: он зовёт Gladiator.reset_state, а тот
## ставит health = max_health и снимает _downed. То есть поверженный напарник
## бесплатно поднимался бы на каждом переходе в дверь, а здоровье команды
## восстанавливалось бы полностью. Заодно отпадает нужда переносить здоровье
## долей: max_health при переходе не меняется, и абсолютное значение просто
## сохраняется само.
func clear_room() -> void:
	for z in _pool:
		if z.is_alive() or z.retiring:
			z.deactivate()
	for p in _potions:
		p.deactivate()
	revive_progress = 0.0
	revive_target = null
	_wave_live = false
	_alive_count = 0
	wave_index = 0
	_started = true


# --- Данные для наблюдений / отладочного HUD ---

func get_alive_zombies() -> Array[Zombie]:
	var result: Array[Zombie] = []
	for z in _pool:
		if z.is_alive():
			result.append(z)
	return result


func get_alive_count() -> int:
	return _alive_count

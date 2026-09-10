class_name GladiatorBrain
extends Node3D

## ВСЯ RL-ЛОГИКА ГЛАДИАТОРА: наблюдения, награды, действия, границы эпизода.
##
## Осознанно НЕ наследует AIController3D. Плагин godot_rl_agents подключается
## отдельным тонким адаптером (GladiatorAIController.gd), а этот файл ни от чего
## не зависит. Что это даёт:
##   * логику можно прогонять и отлаживать без Python и без плагина;
##   * смена RL-фреймворка меняет адаптер, а не функцию наград;
##   * ошибку в наградах видно в обычном запуске игры, а не только в обучении.

@export_group("Наблюдения")
## Сколько чисел в наблюдении помимо двух лидаров: 7 своё состояние,
## 6 ближайший враг, 2 своя скорость, 1 обстановка, 4 ближайшее зелье.
##
## Вынесено в константу не для красоты. Это же число нужно меню, чтобы
## отличить устаревшую политику от подходящей, и раньше оно было переписано
## там вторым экземпляром. Разъехавшись, две копии дали бы молчаливую
## поломку: меню считало бы годной модель, которую движок не примет.
const EXTRA_OBS := 25

@export var lidar_rays: int = 16
@export var lidar_range: float = 12.0
@export var max_tracked_enemies: int = 8   ## для нормализации счётчика врагов

@export_group("Эпизод")
@export var max_episode_steps: int = 3000  ## 50 секунд при 60 Гц

@export_group("Награды: положительные")
@export var w_damage_dealt: float = 1.0    ## за урон, нормированный на удар мечом
@export var w_kill: float = 3.0
@export var w_block: float = 0.6           ## за каждые 10 единиц поглощённого урона
@export var w_wave: float = 1.0            ## за пережитую волну
## Награда за ФАКТИЧЕСКИ восстановленное здоровье, а не за факт подбора.
## Иначе агент бросает бой и наматывает круги по зельям на полном HP.
@export var w_heal: float = 4.0

@export_group("Команда")
## Доля награды напарника, которая приходит и мне. Ноль означает чистый
## эгоизм: агенты начинают драться за добивания и не помогают друг другу.
## Единица - общий котёл, и появляется безбилетник: одному выгодно стоять
## в стороне, пока второй работает. Рабочая середина - около трети.
@export var team_share: float = 0.35
## Гибель напарника обязана быть дорогой, иначе «команда» сводится к тому,
## что двое просто дерутся рядом.
@export var w_ally_death: float = 4.0
## Эпизод заканчивается вместе с гибелью любого из двоих. Это и есть
## главный рычаг кооперации: бросить напарника нельзя, его смерть обрывает
## забег обоим. Без этого выгодной остаётся тактика «пусть его съедят,
## пока я добиваю остальных».
@export var end_on_ally_death: bool = true

@export_group("Награды: отрицательные")
@export var w_damage_taken: float = 1.5    ## за долю max_health
@export var w_miss: float = 0.3            ## промах - штраф за спам атаками
## Штраф за удержание щита, когда рядом никого нет (за физический шаг).
## Без него у "стоять в блоке посреди пустой арены" нулевая цена, а значит
## и нулевой градиент - поведение не уходит само.
@export var w_idle_block: float = 0.001
@export var idle_block_distance: float = 4.0
@export var w_guard_break: float = 0.5
@export var w_death: float = 8.0
@export var w_time: float = 0.0015         ## штраф за шаг - против промедления

@export_group("Награды: наведение (shaping)")
## Осторожно: любой shaping - это подсказка "как надо". Слишком сильная
## награда за сближение учит лезть в толпу и умирать. По умолчанию выключено.
@export var w_approach: float = 0.0

@export_group("Действия")
## Порог срабатывания атак и блока.
##
## КЛЮЧЕВОЙ ПАРАМЕТР. Выход непрерывной политики распределён вокруг нуля
## со std около 1, поэтому при пороге 0.0 атака и блок включаются примерно
## в половине случаев ПРОСТО ОТ ШУМА: агент машет мечом в пустоту и держит
## щит без причины, потому что "не нажимать" ему ничего не стоит.
## Ненулевой порог требует от сети явного намерения.
@export var action_threshold: float = 0.4

# --- Состояние эпизода ---
var steps: int = 0
var done: bool = false
var needs_reset: bool = false
var episode_reward: float = 0.0

var _reward_acc: float = 0.0               ## копится между запросами get_reward()
var _prev_nearest_dist: float = -1.0

# Диагностика поведения: по ним видно, машет ли агент мечом в пустоту
# и держит ли щит без причины.
var stat_attacks: int = 0
var stat_sword: int = 0
var stat_kicks: int = 0
var stat_misses: int = 0
var stat_idle_block_steps: int = 0
var stat_damage_dealt: float = 0.0
var stat_damage_taken: float = 0.0
var stat_blocks: int = 0
var stat_absorbed: float = 0.0
var stat_staggers: int = 0
var stat_guard_breaks: int = 0
var stat_potions: int = 0
var stat_healed: float = 0.0
var _last_wave: int = 0
var _ally: Gladiator = null

var _g: Gladiator
var _arena: Arena
var _lidar_enemy: Lidar3D
var _lidar_wall: Lidar3D

var _obs: Array[float] = []
var _obs_size: int = 0


func _ready() -> void:
	_g = get_parent() as Gladiator
	if _g == null:
		push_error("GladiatorBrain должен быть дочерней нодой Gladiator")
		return

	_arena = _find_arena()
	_build_sensors()

	_obs_size = observation_size_for(lidar_rays)
	_obs.resize(_obs_size)

	_connect_rewards()
	_g.respawned.connect(reset)
	# Напарник создаётся в Arena._ready(), то есть ПОЗЖЕ, чем _ready() Brain
	# (дети инициализируются раньше родителя). Поэтому связываемся отложенно.
	_link_teammate.call_deferred()
	reset()


## Подписка на события напарника: часть его успехов становится моей наградой,
## а его гибель - моим штрафом. Это единственное место, где агент вообще
## узнаёт, что он не один.
func _link_teammate() -> void:
	if _arena == null or _ally != null:
		return
	for f in _arena.get_fighters():
		if f != _g:
			_ally = f
			break
	if _ally == null:
		return

	_ally.enemy_killed.connect(_on_ally_killed)
	_ally.dealt_damage.connect(_on_ally_damage)
	_ally.died.connect(_on_ally_died)


func _on_ally_killed(_target: Node3D) -> void:
	_add_reward(w_kill * team_share)


func _on_ally_damage(amount: float, _target: Node3D, _type: int) -> void:
	_add_reward(w_damage_dealt * team_share * amount / maxf(_g.sword_damage, 0.001))


func _on_ally_died() -> void:
	_add_reward(-w_ally_death)
	if end_on_ally_death:
		done = true
		needs_reset = true


func has_teammate() -> bool:
	return _ally != null and is_instance_valid(_ally)


func _find_arena() -> Arena:
	var n: Node = _g
	while n != null:
		if n is Arena:
			return n
		n = n.get_parent()
	push_warning("GladiatorBrain: Arena не найдена, часть наблюдений будет нулевой")
	return null


## Brain - Node3D и висит в начале координат гладиатора, поэтому лидары можно
## сделать его собственными детьми: они автоматически едут и поворачиваются
## вместе с телом, а add_child() к самому себе безопасен в _ready().
func _build_sensors() -> void:
	_lidar_enemy = Lidar3D.new()
	_lidar_enemy.name = "LidarEnemy"
	_lidar_enemy.ray_count = lidar_rays
	_lidar_enemy.ray_length = lidar_range
	_lidar_enemy.layer_mask = 4                # Enemy
	add_child(_lidar_enemy)

	_lidar_wall = Lidar3D.new()
	_lidar_wall.name = "LidarWall"
	_lidar_wall.ray_count = lidar_rays
	_lidar_wall.ray_length = lidar_range
	_lidar_wall.layer_mask = 1                 # World
	add_child(_lidar_wall)

	_lidar_enemy.exclude_body(_g)
	_lidar_wall.exclude_body(_g)


# ------------------------------------------------------------------
# Награды
# ------------------------------------------------------------------

func _connect_rewards() -> void:
	_g.dealt_damage.connect(_on_dealt_damage)
	_g.enemy_killed.connect(_on_enemy_killed)
	_g.attack_started.connect(_on_attack_started)
	_g.attack_missed.connect(_on_attack_missed)
	_g.took_damage.connect(_on_took_damage)
	_g.damage_blocked.connect(_on_damage_blocked)
	_g.guard_broken.connect(_on_guard_broken)
	_g.attacker_staggered.connect(_on_attacker_staggered)
	_g.healed.connect(_on_healed)
	_g.died.connect(_on_died)


func _add_reward(r: float) -> void:
	_reward_acc += r
	episode_reward += r


func _on_attack_started(type: int) -> void:
	stat_attacks += 1
	if type == Gladiator.AttackType.KICK:
		stat_kicks += 1
	else:
		stat_sword += 1


func _on_dealt_damage(amount: float, _target: Node3D, _type: int) -> void:
	stat_damage_dealt += amount
	# Нормируем на урон одного удара мечом, чтобы вес не зависел от баланса
	_add_reward(w_damage_dealt * amount / maxf(_g.sword_damage, 0.001))


func _on_enemy_killed(_target: Node3D) -> void:
	_add_reward(w_kill)


func _on_attack_missed(_type: int) -> void:
	stat_misses += 1
	_add_reward(-w_miss)


func _on_took_damage(amount: float, _blocked: bool) -> void:
	stat_damage_taken += amount
	_add_reward(-w_damage_taken * amount / maxf(_g.max_health, 0.001))


func _on_damage_blocked(absorbed: float) -> void:
	stat_blocks += 1
	stat_absorbed += absorbed
	# Награда только за РЕАЛЬНО поглощённый урон. Награждать за сам факт
	# удержания щита нельзя - агент немедленно найдёт стратегию "стоять в блоке".
	_add_reward(w_block * absorbed / 10.0)


func _on_guard_broken() -> void:
	stat_guard_breaks += 1
	_add_reward(-w_guard_break)


func _on_died() -> void:
	_add_reward(-w_death)
	done = true
	needs_reset = true


func _on_attacker_staggered(_target: Node3D) -> void:
	stat_staggers += 1


func _on_healed(amount: float) -> void:
	stat_potions += 1
	stat_healed += amount
	_add_reward(w_heal * amount / maxf(_g.max_health, 0.001))


## Забрать накопленную награду. Вызывается ровно раз за шаг обучения.
func consume_reward() -> float:
	var r := _reward_acc
	_reward_acc = 0.0
	return r


# ------------------------------------------------------------------
# Шаг эпизода
# ------------------------------------------------------------------

## Вызывается каждый физический шаг (адаптером или тестом).
func step() -> void:
	steps += 1
	_add_reward(-w_time)

	if _arena != null and _arena.wave_index > _last_wave:
		if _last_wave > 0:
			_add_reward(w_wave)
		_last_wave = _arena.wave_index

	if _g.is_blocking and w_idle_block > 0.0:
		var nearest := _nearest_enemy()
		var threat_dist := INF
		if nearest != null:
			threat_dist = nearest.global_position.distance_to(_g.global_position)
		if threat_dist > idle_block_distance:
			stat_idle_block_steps += 1
			_add_reward(-w_idle_block)

	if w_approach != 0.0:
		_apply_approach_shaping()

	# Обрыв по лимиту шагов - это truncation, а не поражение:
	# штрафа за смерть здесь быть не должно.
	if steps >= max_episode_steps:
		done = true
		needs_reset = true


func _apply_approach_shaping() -> void:
	var nearest := _nearest_enemy()
	if nearest == null:
		_prev_nearest_dist = -1.0
		return

	var d: float = nearest.global_position.distance_to(_g.global_position)
	if _prev_nearest_dist >= 0.0:
		_add_reward(w_approach * (_prev_nearest_dist - d))
	_prev_nearest_dist = d


## Полный сброс окружения. Адаптер RL вызывает его, когда needs_reset = true.
func reset_environment() -> void:
	if _arena != null:
		_arena.reset_arena()    # он эмитит respawned -> reset()
	else:
		reset()


func reset() -> void:
	steps = 0
	done = false
	needs_reset = false
	episode_reward = 0.0
	_reward_acc = 0.0
	_prev_nearest_dist = -1.0
	stat_attacks = 0
	stat_sword = 0
	stat_kicks = 0
	stat_misses = 0
	stat_idle_block_steps = 0
	stat_damage_dealt = 0.0
	stat_damage_taken = 0.0
	stat_blocks = 0
	stat_absorbed = 0.0
	stat_staggers = 0
	stat_guard_breaks = 0
	stat_potions = 0
	stat_healed = 0.0
	_last_wave = _arena.wave_index if _arena != null else 0


# ------------------------------------------------------------------
# Действия
# ------------------------------------------------------------------

## action: [move, turn, sword, kick, block], все в диапазоне -1..1.
##
## Атаки и блок - пороговые. Так они укладываются в непрерывное пространство
## Box(5), которое понимает Stable-Baselines3: смешанные (Dict/Tuple) action
## spaces SB3 не поддерживает, а движение хочется непрерывным.
func apply_action(action: PackedFloat32Array) -> void:
	if action.size() < 5 or not _g.is_alive():
		return

	_g.intent_move = clampf(action[0], -1.0, 1.0)
	_g.intent_turn = clampf(action[1], -1.0, 1.0)

	if action[2] > action_threshold:
		_g.intent_sword = true
	if action[3] > action_threshold:
		_g.intent_kick = true
	_g.intent_block = action[4] > action_threshold


# ------------------------------------------------------------------
# Наблюдения
# ------------------------------------------------------------------

## Все компоненты лежат в -1..1 и выражены в системе координат гладиатора.
## Эгоцентричность обязательна: на мировых координатах агенту пришлось бы
## отдельно выучивать инвариантность к повороту и к позиции на арене.
func get_observation() -> Array[float]:
	var i := 0

	var enemy := _lidar_enemy.sense()
	for v in enemy:
		_obs[i] = v
		i += 1

	var wall := _lidar_wall.sense()
	for v in wall:
		_obs[i] = v
		i += 1

	# --- Собственное состояние (7) ---
	_obs[i] = _g.get_health_ratio();          i += 1
	_obs[i] = _g.get_block_stamina_ratio();   i += 1
	_obs[i] = _g.get_sword_ready_ratio();     i += 1
	_obs[i] = _g.get_kick_ready_ratio();      i += 1
	_obs[i] = 1.0 if _g.is_blocking else 0.0; i += 1
	_obs[i] = _g.get_stun_ratio();            i += 1
	_obs[i] = clampf(_g.action_lock / maxf(_g.sword_lock_time, 0.001), 0.0, 1.0); i += 1

	# --- Ближайший враг (6) ---
	#
	# Тип врага здесь обязателен. Бегун вдвое слабее и в 1.75 раза быстрее
	# обычного, громила - в 2.6 раза живучее и почти вдвое медленнее. Драться
	# с ними надо по-разному, а сеть у нас без памяти и без стекирования
	# кадров: по одному кадру видно только положение, но не скорость. Без
	# явного признака агент физически не может отличить одного от другого и
	# сходится к усреднённой тактике, проигрышной против обоих.
	var basis_t := _g.global_transform.basis.transposed()
	var nearest := _nearest_enemy()
	if nearest != null:
		var to_t: Vector3 = nearest.global_position - _g.global_position
		to_t.y = 0.0
		var dist := to_t.length()
		var local := basis_t * to_t.normalized()
		_obs[i] = local.x;                                        i += 1   # вправо
		_obs[i] = -local.z;                                       i += 1   # вперёд
		_obs[i] = clampf(1.0 - dist / lidar_range, 0.0, 1.0);     i += 1
		_obs[i] = 1.0 if nearest.state == Zombie.State.WINDUP else 0.0; i += 1
		# Обычный зомби - это оба нуля, отдельного признака ему не нужно.
		_obs[i] = 1.0 if nearest.variant == Zombie.Variant.RUNNER else 0.0; i += 1
		_obs[i] = 1.0 if nearest.variant == Zombie.Variant.BRUTE else 0.0;  i += 1
	else:
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1

	# --- Собственная скорость в локальных осях (2) ---
	var v_local := basis_t * _g.velocity
	_obs[i] = clampf(v_local.x / maxf(_g.move_speed, 0.001), -1.0, 1.0);  i += 1
	_obs[i] = clampf(-v_local.z / maxf(_g.move_speed, 0.001), -1.0, 1.0); i += 1

	# --- Обстановка (1) ---
	var alive := _arena.get_alive_count() if _arena != null else 0
	_obs[i] = clampf(float(alive) / float(max_tracked_enemies), 0.0, 1.0); i += 1

	# --- Ближайшее зелье (4) ---
	# Без этих компонент агент физически не может научиться лечиться:
	# зелья для него просто не существуют.
	var potion := _nearest_potion()
	if potion != null:
		var to_p: Vector3 = potion.global_position - _g.global_position
		to_p.y = 0.0
		var pd := to_p.length()
		var lp := basis_t * to_p.normalized()
		_obs[i] = lp.x;                                        i += 1   # вправо
		_obs[i] = -lp.z;                                       i += 1   # вперёд
		_obs[i] = clampf(1.0 - pd / lidar_range, 0.0, 1.0);    i += 1
		_obs[i] = 1.0;                                         i += 1   # зелье есть
	else:
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1
		_obs[i] = 0.0; i += 1

	return _obs


func get_observation_size() -> int:
	return _obs_size


## Размер наблюдения по числу лучей лидара, без создания самого мозга.
## Нужен меню, чтобы отличить устаревшую политику от подходящей.
static func observation_size_for(rays: int) -> int:
	return rays * 2 + EXTRA_OBS


func _nearest_enemy() -> Zombie:
	if _arena == null:
		return null

	var best: Zombie = null
	var best_d := INF
	for z in _arena.get_alive_zombies():
		var d: float = z.global_position.distance_squared_to(_g.global_position)
		if d < best_d:
			best_d = d
			best = z
	return best


func _nearest_potion() -> Potion:
	if _arena == null:
		return null

	var best: Potion = null
	var best_d := INF
	for p in _arena.get_active_potions():
		var d: float = p.global_position.distance_squared_to(_g.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best


## Диагностика для мониторинга обучения (TensorBoard / консоль).
func get_stats() -> Dictionary:
	return {
		"episode_reward": episode_reward,
		"steps": steps,
		"kills": _arena.total_kills if _arena != null else 0,
		"wave": _arena.wave_index if _arena != null else 0,
		"health": _g.health,
		"attacks": stat_attacks,
		"sword": stat_sword,
		"kicks": stat_kicks,
		"misses": stat_misses,
		"miss_rate": float(stat_misses) / maxf(float(stat_attacks), 1.0),
		"idle_block": stat_idle_block_steps,
		"damage_dealt": stat_damage_dealt,
		"damage_taken": stat_damage_taken,
		"blocks": stat_blocks,
		"absorbed": stat_absorbed,
		"staggers": stat_staggers,
		"guard_breaks": stat_guard_breaks,
		"potions": stat_potions,
		"healed": stat_healed,
		"ally_alive": 1.0 if (has_teammate() and _ally.is_alive()) else 0.0,
	}

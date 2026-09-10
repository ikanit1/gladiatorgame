class_name Gladiator
extends CharacterBody3D

## ЧИСТАЯ МЕХАНИКА ГЛАДИАТОРА.
##
## Принцип: этот скрипт НЕ читает Input и НЕ знает про ИИ.
## Он только исполняет "намерения" (intent_*), которые ему выставляет
## внешний источник управления - PlayerInput.gd (руками) или AIController.gd (ИИ).
## Благодаря этому обучение и ручная отладка используют ОДИН И ТОТ ЖЕ код механики.
##
## Все сигналы ниже - будущие точки подключения функции наград.

# --- Сигналы для системы наград ---
signal dealt_damage(amount: float, target: Node3D, attack_type: int)
signal enemy_killed(target: Node3D)
signal attack_started(attack_type: int)  ## удар начат (для визуала и звука)
signal attack_missed(attack_type: int)   ## промах - штрафуем за спам атаками
signal took_damage(amount: float, blocked: bool)
signal damage_blocked(absorbed: float)   ## сколько урона съел щит - награждаем
signal attacker_staggered(target: Node3D) ## блок отбросил атакующего
signal guard_broken()                    ## щит пробит, гладиатор в стане
signal downed()                          ## повержен, но его ещё можно поднять
signal revived(health_left: float)
signal died()
signal healed(amount: float)             ## сколько HP реально восстановлено
signal respawned()                       ## после reset_state - сброс визуала

enum AttackType { SWORD, KICK }

@export_group("Здоровье")
@export var max_health: float = 100.0
## Вместо смерти боец падает и ждёт помощи. Включается только в игре:
## при обучении лишнее состояние сбило бы границы эпизода.
@export var downed_enabled: bool = false
## Сколько секунд лежит, прежде чем добьют окончательно. 0 - без лимита.
@export var downed_timeout: float = 25.0
@export var revive_health: float = 45.0

@export_group("Движение")
@export var move_speed: float = 5.0
@export var back_speed_mult: float = 0.6      ## назад ходим медленнее
@export var block_speed_mult: float = 0.4     ## щит замедляет
@export var attack_speed_mult: float = 0.25   ## во время отката атаки почти стоим
@export var turn_speed_deg: float = 220.0
@export var acceleration: float = 30.0

@export_group("Ручное управление")
@export var human_turn_speed_deg: float = 900.0
@export var human_acceleration: float = 48.0
@export var human_braking: float = 64.0
@export var human_block_speed_mult: float = 0.65
@export var human_attack_speed_mult: float = 0.65

@export_group("Меч")
@export var sword_damage: float = 34.0
@export var sword_cooldown: float = 0.7
@export var sword_range: float = 2.2
@export var sword_arc_deg: float = 100.0
@export var sword_max_targets: int = 3        ## меч бьёт по дуге, задевает нескольких
@export var sword_lock_time: float = 0.3      ## окно уязвимости после замаха

@export_group("Пинок")
@export var kick_damage: float = 6.0
@export var kick_cooldown: float = 1.8
@export var kick_range: float = 1.8
@export var kick_arc_deg: float = 55.0
@export var kick_knockback: float = 3.0    ## лёгкий толчок, а не отброс через пол-арены
## 3 секунды - это дольше, чем интервал атаки зомби (1.3 с), поэтому пинок
## теперь не столько урон, сколько полное выключение цели из боя.
@export var kick_stun_time: float = 3.0
@export var kick_lock_time: float = 0.2

@export_group("Блок")
@export var block_arc_deg: float = 130.0          ## сектор защиты спереди
@export var block_damage_reduction: float = 1.0   ## 1.0 = щит гасит урон полностью
## Успешный блок отбрасывает и оглушает атакующего. Это превращает щит из
## пассивной защиты в инструмент контроля, но цена остаётся: стамина под
## щитом только тратится (14/сек) и не восстанавливается, так что бесконечно
## танковать нельзя - через ~7 секунд удержания приходит guard break.
@export var block_stagger_time: float = 0.8
@export var block_knockback: float = 5.0
@export var block_stamina_max: float = 100.0
@export var block_stamina_drain: float = 14.0     ## в секунду при удержании
@export var block_stamina_hit_cost: float = 20.0  ## за каждый поглощённый удар
@export var block_stamina_regen: float = 25.0     ## в секунду когда щит опущен
@export var guard_break_stun: float = 1.0         ## стан при пробитии блока

# --- НАМЕРЕНИЯ (пишет контроллер: PlayerInput или AIController) ---
var intent_move: float = 0.0     ## -1..1 (назад / вперёд)
var intent_turn: float = 0.0     ## -1..1 (влево / вправо)
var intent_block: bool = false   ## удерживаемое состояние
var intent_sword: bool = false   ## одноразовое, потребляется за кадр
var intent_kick: bool = false    ## одноразовое, потребляется за кадр
var intent_revive: bool = false  ## удерживаемое: поднимаю напарника

## Opt-in manual movement; these fields are not part of the RL action vector.
var human_movement: bool = false
var intent_move_world := Vector3.ZERO
var intent_facing_yaw: float = 0.0

# --- Состояние ---
var health: float
var block_stamina: float
var sword_cd: float = 0.0
var kick_cd: float = 0.0
var action_lock: float = 0.0   ## пока > 0 - нельзя атаковать/блокировать
var stun_time: float = 0.0
var is_blocking: bool = false

var _alive: bool = true
var _downed: bool = false
var downed_time_left: float = 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)

# Кешированный запрос формы. Дешевле, чем постоянно активный Area3D,
# и не создаёт мусор каждый удар - важно при сотнях арен в headless.
var _attack_shape: SphereShape3D
var _attack_query: PhysicsShapeQueryParameters3D


func _ready() -> void:
	_attack_shape = SphereShape3D.new()
	_attack_query = PhysicsShapeQueryParameters3D.new()
	_attack_query.shape = _attack_shape
	_attack_query.collide_with_areas = false
	_attack_query.collide_with_bodies = true
	_attack_query.collision_mask = 4          # слой 3 = "Enemy"
	_attack_query.exclude = [get_rid()]

	health = max_health
	block_stamina = block_stamina_max


func _physics_process(delta: float) -> void:
	if not _alive and not _downed:
		# Труп всё равно должен лежать на полу, а не висеть в воздухе
		_apply_gravity(delta)
		move_and_slide()
		return

	if _downed:
		_tick_downed(delta)
		_apply_gravity(delta)
		move_and_slide()
		return

	_tick_timers(delta)
	if human_movement and stun_time <= 0.0:
		global_rotation.y = rotate_toward(global_rotation.y, intent_facing_yaw,
			deg_to_rad(human_turn_speed_deg) * delta)
	_update_block(delta)
	_handle_attacks()
	_handle_movement(delta)
	_consume_intents()


# ------------------------------------------------------------------
# Таймеры / состояния
# ------------------------------------------------------------------

func _tick_downed(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
	if downed_timeout <= 0.0:
		return
	downed_time_left = maxf(0.0, downed_time_left - delta)
	if downed_time_left <= 0.0:
		_downed = false
		_die()


func _tick_timers(delta: float) -> void:
	sword_cd = maxf(0.0, sword_cd - delta)
	kick_cd = maxf(0.0, kick_cd - delta)
	action_lock = maxf(0.0, action_lock - delta)
	stun_time = maxf(0.0, stun_time - delta)


func _update_block(delta: float) -> void:
	var can_block := intent_block and stun_time <= 0.0 and action_lock <= 0.0 and block_stamina > 0.0
	is_blocking = can_block

	if is_blocking:
		block_stamina = maxf(0.0, block_stamina - block_stamina_drain * delta)
	else:
		block_stamina = minf(block_stamina_max, block_stamina + block_stamina_regen * delta)


func _consume_intents() -> void:
	# Одноразовые намерения обнуляем, чтобы удар не повторялся сам собой
	intent_sword = false
	intent_kick = false


# ------------------------------------------------------------------
# Движение
# ------------------------------------------------------------------

func _handle_movement(delta: float) -> void:
	var speed_mult := 1.0
	if stun_time > 0.0:
		speed_mult = 0.0
	elif action_lock > 0.0:
		speed_mult = human_attack_speed_mult if human_movement else attack_speed_mult
	elif is_blocking:
		speed_mult = human_block_speed_mult if human_movement else block_speed_mult

	# Поворот (положительный intent_turn = вправо)
	if stun_time <= 0.0 and not human_movement:
		rotate_y(-intent_turn * deg_to_rad(turn_speed_deg) * delta)

	var move_input := intent_move
	if move_input < 0.0:
		move_input *= back_speed_mult

	var target_vel := forward() * move_input * move_speed * speed_mult
	if human_movement:
		var wish := Vector3(intent_move_world.x, 0.0, intent_move_world.z).limit_length(1.0)
		if is_blocking and wish.length_squared() > 0.001:
			var retreat := maxf(0.0, -wish.normalized().dot(forward()))
			wish *= lerpf(1.0, back_speed_mult, retreat)
		target_vel = wish * move_speed * speed_mult
		var horizontal := Vector3(velocity.x, 0.0, velocity.z)
		var braking := wish.is_zero_approx() or horizontal.dot(target_vel) < 0.0
		horizontal = horizontal.move_toward(target_vel,
			(human_braking if braking else human_acceleration) * delta)
		velocity.x = horizontal.x
		velocity.z = horizontal.z
	else:
		velocity.x = move_toward(velocity.x, target_vel.x, acceleration * delta)
		velocity.z = move_toward(velocity.z, target_vel.z, acceleration * delta)

	_apply_gravity(delta)
	move_and_slide()


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0


# ------------------------------------------------------------------
# Атаки
# ------------------------------------------------------------------

func _handle_attacks() -> void:
	if stun_time > 0.0 or action_lock > 0.0:
		return
	# Wait for the body to face manual aim before an instantaneous hit query.
	if human_movement and absf(wrapf(intent_facing_yaw - global_rotation.y, -PI, PI)) > deg_to_rad(25.0):
		return

	if intent_sword and sword_cd <= 0.0:
		sword_cd = sword_cooldown
		action_lock = sword_lock_time
		is_blocking = false   # нельзя бить и держать щит одновременно
		attack_started.emit(AttackType.SWORD)
		_perform_attack(sword_range, sword_arc_deg, sword_damage, 0.0, 0.0,
				sword_max_targets, AttackType.SWORD)
		return   # за один кадр - одна атака

	if intent_kick and kick_cd <= 0.0:
		kick_cd = kick_cooldown
		action_lock = kick_lock_time
		is_blocking = false
		attack_started.emit(AttackType.KICK)
		_perform_attack(kick_range, kick_arc_deg, kick_damage, kick_knockback,
				kick_stun_time, 1, AttackType.KICK)


## Мгновенная проверка попадания: сфера вокруг гладиатора + фильтр по дуге.
func _perform_attack(atk_range: float, arc_deg: float, damage: float,
		knockback: float, stun: float, max_targets: int, type: int) -> void:

	_attack_shape.radius = atk_range
	_attack_query.transform = Transform3D(Basis(), global_position + Vector3.UP * 0.9)

	var hits := get_world_3d().direct_space_state.intersect_shape(_attack_query, 32)
	var fwd := forward()
	var half_arc := deg_to_rad(arc_deg) * 0.5

	var candidates: Array = []
	for h in hits:
		var body: Object = h.get("collider")
		if body == null or not (body is Zombie):
			continue
		var z: Zombie = body
		if not z.is_alive():
			continue
		var to_t: Vector3 = z.global_position - global_position
		to_t.y = 0.0
		var dist := to_t.length()
		if dist < 0.001:
			continue
		if fwd.angle_to(to_t / dist) > half_arc:
			continue
		candidates.append({"body": z, "dist": dist})

	if candidates.is_empty():
		attack_missed.emit(type)
		return

	candidates.sort_custom(func(a, b): return a["dist"] < b["dist"])

	for i in mini(max_targets, candidates.size()):
		var z: Zombie = candidates[i]["body"]
		var killed := z.take_damage(damage, global_position, knockback, stun)
		dealt_damage.emit(damage, z, type)
		if killed:
			enemy_killed.emit(z)


# ------------------------------------------------------------------
# Получение урона
# ------------------------------------------------------------------

## source нужен, чтобы успешный блок мог оглушить конкретного атакующего.
func take_damage(amount: float, source_position: Vector3, source: Node3D = null) -> void:
	# Поверженный уже вне боя: добить его может только истёкший таймер,
	# иначе случайный удар по площади отнимал бы шанс на подъём.
	if not _alive or _downed:
		return

	var blocked := false
	var final_damage := amount

	if is_blocking:
		var to_src := source_position - global_position
		to_src.y = 0.0
		if to_src.length_squared() > 0.0001:
			var angle := forward().angle_to(to_src.normalized())
			if angle <= deg_to_rad(block_arc_deg) * 0.5:
				blocked = true
				final_damage = amount * (1.0 - block_damage_reduction)
				damage_blocked.emit(amount - final_damage)
				block_stamina -= block_stamina_hit_cost
				_stagger_attacker(source)
				if block_stamina <= 0.0:
					_break_guard()

	health -= final_damage
	took_damage.emit(final_damage, blocked)

	if health <= 0.0:
		health = 0.0
		if downed_enabled and not _downed:
			_enter_downed()
		else:
			_die()


## Отбрасывает атакующего после удачного блока.
func _stagger_attacker(source: Node3D) -> void:
	if block_stagger_time <= 0.0 or source == null or not (source is Zombie):
		return
	var z: Zombie = source
	if not z.is_alive():
		return
	z.stagger(block_stagger_time, global_position, block_knockback)
	attacker_staggered.emit(z)


## Возвращает, сколько здоровья РЕАЛЬНО восстановлено.
## Именно эта величина, а не факт подбора, идёт в награду: иначе агент начнёт
## собирать зелья на полном HP вместо того, чтобы драться.
func heal(amount: float) -> float:
	if not is_alive() or amount <= 0.0:
		return 0.0
	var before := health
	health = minf(max_health, health + amount)
	var gained := health - before
	if gained > 0.0:
		healed.emit(gained)
	return gained


## Именно is_alive(), а не _alive: поверженный лечиться не может, и без этой
## проверки арена скармливала бы ему зелья, которые heal() всё равно отвергает.
func needs_healing() -> bool:
	return is_alive() and health < max_health


func _break_guard() -> void:
	block_stamina = 0.0
	is_blocking = false
	stun_time = maxf(stun_time, guard_break_stun)
	guard_broken.emit()


## Падение вместо смерти: боец выбывает из боя, но остаётся на арене.
func _enter_downed() -> void:
	_downed = true
	is_blocking = false
	velocity = Vector3.ZERO
	intent_move = 0.0
	intent_turn = 0.0
	downed_time_left = downed_timeout
	downed.emit()


## Поднять поверженного. Возвращает false, если поднимать нечего.
func revive(amount: float = -1.0) -> bool:
	if not _downed:
		return false
	_downed = false
	_alive = true
	health = clampf(amount if amount > 0.0 else revive_health, 1.0, max_health)
	block_stamina = block_stamina_max
	sword_cd = 0.0
	kick_cd = 0.0
	action_lock = 0.0
	stun_time = 0.0
	downed_time_left = 0.0
	revived.emit(health)
	return true


func is_downed() -> bool:
	return _downed


## Доля оставшегося времени до окончательной смерти (для полосы в HUD).
func get_downed_ratio() -> float:
	if not _downed or downed_timeout <= 0.0:
		return 1.0
	return clampf(downed_time_left / downed_timeout, 0.0, 1.0)


func _die() -> void:
	if not _alive:
		return
	_alive = false
	# Обязательно снять: иначе боец остаётся одновременно мёртвым и
	# «поднимаемым», и revive() воскрешает того, кто уже погиб окончательно.
	_downed = false
	downed_time_left = 0.0
	is_blocking = false
	velocity = Vector3.ZERO
	died.emit()


# ------------------------------------------------------------------
# Публичный API
# ------------------------------------------------------------------

## Поверженный НЕ считается живым: он не цель для зомби, не действует
## и не участвует в наблюдениях как боец. Для "ещё не проиграл" есть is_downed().
func is_alive() -> bool:
	return _alive and not _downed


func forward() -> Vector3:
	return -global_transform.basis.z


## Полный сброс без пересоздания ноды - обязательное условие для RL:
## queue_free()/instantiate() на каждом эпизоде даёт просадку и фрагментацию памяти.
func reset_state(spawn_transform: Transform3D) -> void:
	global_transform = spawn_transform
	velocity = Vector3.ZERO
	health = max_health
	block_stamina = block_stamina_max
	sword_cd = 0.0
	kick_cd = 0.0
	action_lock = 0.0
	stun_time = 0.0
	is_blocking = false
	_alive = true
	_downed = false
	downed_time_left = 0.0
	intent_move = 0.0
	intent_turn = 0.0
	intent_block = false
	intent_sword = false
	intent_kick = false
	intent_revive = false
	intent_move_world = Vector3.ZERO
	intent_facing_yaw = global_rotation.y
	respawned.emit()


# --- Нормализованные геттеры (0..1) - готовые компоненты вектора наблюдений ---

func get_health_ratio() -> float:
	return health / max_health

func get_sword_ready_ratio() -> float:
	return 1.0 - (sword_cd / sword_cooldown)

func get_kick_ready_ratio() -> float:
	return 1.0 - (kick_cd / kick_cooldown)

func get_block_stamina_ratio() -> float:
	return block_stamina / block_stamina_max

func get_stun_ratio() -> float:
	return clampf(stun_time / maxf(guard_break_stun, 0.001), 0.0, 1.0)

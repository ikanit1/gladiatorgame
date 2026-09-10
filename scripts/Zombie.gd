class_name Zombie
extends CharacterBody3D

## Простой противник с конечным автоматом. НИКАКОГО ИИ-обучения здесь нет -
## зомби должен быть предсказуемым, иначе гладиатор будет учиться против шума.
##
## ВАЖНО: цель (target) выставляется извне спавнером арены.
## НЕЛЬЗЯ искать игрока через get_tree().get_nodes_in_group() - при обучении
## на сцене будут десятки арен, и зомби побежит к чужому гладиатору.

signal died(zombie: Zombie)
signal hit_player(damage: float)
signal damaged(amount: float)      ## для визуальной вспышки
signal respawned()                 ## взят из пула - сбросить визуал

enum State { IDLE, CHASE, WINDUP, RECOVER, STAGGER, DEAD }

## Разновидности. Множители применяются к БАЗОВЫМ значениям, а не к текущим:
## иначе при переиспользовании из пула они бы накапливались от волны к волне.
enum Variant { NORMAL, RUNNER, BRUTE }

@export_group("Характеристики")
@export var max_health: float = 45.0   ## 2 удара мечом - иначе пинок и блок не нужны
@export var move_speed: float = 3.0
@export var turn_speed_deg: float = 420.0
@export var acceleration: float = 18.0

@export_group("Атака")
@export var attack_damage: float = 12.0
@export var attack_range: float = 1.9
@export var attack_windup: float = 0.45    ## замах - окно, в котором игрок может увернуться/пнуть
@export var attack_recover: float = 0.5
@export var attack_cooldown: float = 1.3

@export_group("Реакция на урон")
@export var knockback_damping: float = 9.0

## Тип намеренно Node3D, а не Gladiator: две взаимные статические ссылки
## (Gladiator -> Zombie и Zombie -> Gladiator) через class_name дают Godot
## циклическую зависимость при разборе скриптов. Здесь вызовы динамические.
var target: Node3D = null   ## ставится ареной при спавне

var health: float
var state: int = State.IDLE

var _timer: float = 0.0
var _attack_cd: float = 0.0
var _knockback: Vector3 = Vector3.ZERO
var _active: bool = false
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 24.0)

var variant: int = Variant.NORMAL
var _base_health: float = 0.0
var _base_speed: float = 0.0
var _base_damage: float = 0.0
var _base_cooldown: float = 0.0
var _threat_health_scale: float = 1.0
var _threat_speed_scale: float = 1.0
var _threat_damage_scale: float = 1.0
var _threat_cooldown_scale: float = 1.0

@onready var _collision: CollisionShape3D = $Collision


func _ready() -> void:
	_base_health = max_health
	_base_speed = move_speed
	_base_damage = attack_damage
	_base_cooldown = attack_cooldown


func _physics_process(delta: float) -> void:
	if not _active or state == State.DEAD:
		return

	_attack_cd = maxf(0.0, _attack_cd - delta)

	if target == null or not target.is_alive():
		state = State.IDLE
	elif state == State.IDLE:
		state = State.CHASE

	match state:
		State.CHASE:
			_state_chase(delta)
		State.WINDUP:
			_state_windup(delta)
		State.RECOVER:
			_state_timed(delta, State.CHASE)
		State.STAGGER:
			_state_timed(delta, State.CHASE)
		State.IDLE:
			_decelerate(delta)

	_apply_knockback(delta)
	_apply_gravity(delta)
	move_and_slide()


# ------------------------------------------------------------------
# Состояния
# ------------------------------------------------------------------

func _state_chase(delta: float) -> void:
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	var dist := to_target.length()

	if dist > 0.001:
		_face(to_target / dist, delta)

	if dist <= attack_range and _attack_cd <= 0.0:
		state = State.WINDUP
		_timer = attack_windup
		_decelerate(delta)
		return

	var dir := to_target.normalized() if dist > 0.001 else Vector3.ZERO
	var target_vel := dir * move_speed
	velocity.x = move_toward(velocity.x, target_vel.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, acceleration * delta)


func _state_windup(delta: float) -> void:
	_decelerate(delta)

	# Во время замаха зомби ещё доворачивается - иначе от него слишком легко уйти
	var to_target := target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() > 0.0001:
		_face(to_target.normalized(), delta * 0.5)

	_timer -= delta
	if _timer > 0.0:
		return

	# Момент удара: проверяем, что цель всё ещё в радиусе
	_attack_cd = attack_cooldown
	state = State.RECOVER
	_timer = attack_recover

	if target != null and target.is_alive() and to_target.length() <= attack_range * 1.15:
		# self передаём, чтобы гладиатор мог оглушить нас успешным блоком
		target.take_damage(attack_damage, global_position, self)
		hit_player.emit(attack_damage)


func _state_timed(delta: float, next_state: int) -> void:
	_decelerate(delta)
	_timer -= delta
	if _timer <= 0.0:
		state = next_state


# ------------------------------------------------------------------
# Урон
# ------------------------------------------------------------------

## Возвращает true, если зомби умер именно от этого удара.
func take_damage(amount: float, from_position: Vector3, knockback: float = 0.0,
		stun: float = 0.0) -> bool:

	if not _active or state == State.DEAD:
		return false

	health -= amount
	damaged.emit(amount)

	if knockback > 0.0:
		var dir := global_position - from_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			_knockback = dir.normalized() * knockback

	if stun > 0.0:
		state = State.STAGGER
		_timer = maxf(_timer, stun)
		_attack_cd = maxf(_attack_cd, stun)   # после стана нельзя бить мгновенно

	if health <= 0.0:
		health = 0.0
		_die()
		return true

	return false


## Оглушение извне (успешный блок щитом). Отдельно от take_damage,
## потому что урона здесь нет - только контроль.
func stagger(duration: float, from_position: Vector3, knockback: float = 0.0) -> void:
	if not is_alive():
		return

	state = State.STAGGER
	_timer = maxf(_timer, duration)
	_attack_cd = maxf(_attack_cd, duration)

	if knockback > 0.0:
		var dir := global_position - from_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			_knockback = dir.normalized() * knockback


func _die() -> void:
	state = State.DEAD
	velocity = Vector3.ZERO
	_knockback = Vector3.ZERO
	died.emit(self)
	# deactivate() вызовет арена из обработчика сигнала - через call_deferred,
	# потому что менять коллизии внутри физического шага нельзя.


# ------------------------------------------------------------------
# Пулинг: вместо queue_free() / instantiate() на каждом эпизоде
# ------------------------------------------------------------------

## Разновидность задаётся ДО activate(): здоровье выставляется от неё.
func set_variant(v: int) -> void:
	variant = v
	_apply_variant_stats()


## Масштаб общей угрозы забега применяется поверх типа зомби. Это отдельно
## от set_variant, чтобы параметры пула не накапливались от волны к волне.
func set_threat_scaling(health_scale: float, speed_scale: float,
		damage_scale: float, cooldown_scale: float) -> void:
	_threat_health_scale = maxf(0.1, health_scale)
	_threat_speed_scale = maxf(0.1, speed_scale)
	_threat_damage_scale = maxf(0.1, damage_scale)
	_threat_cooldown_scale = maxf(0.1, cooldown_scale)
	_apply_variant_stats()


func _apply_variant_stats() -> void:
	var health_mult := 1.0
	var speed_mult := 1.0
	var damage_mult := 1.0
	var cooldown_mult := 1.0
	match variant:
		Variant.RUNNER:
			health_mult = 0.5
			speed_mult = 1.75
			damage_mult = 0.65
			cooldown_mult = 0.75
		Variant.BRUTE:
			health_mult = 2.6
			speed_mult = 0.62
			damage_mult = 1.9
			cooldown_mult = 1.25

	max_health = _base_health * health_mult * _threat_health_scale
	move_speed = _base_speed * speed_mult * _threat_speed_scale
	attack_damage = _base_damage * damage_mult * _threat_damage_scale
	attack_cooldown = _base_cooldown * cooldown_mult * _threat_cooldown_scale


func activate(spawn_transform: Transform3D, new_target: Node3D) -> void:
	global_transform = spawn_transform
	target = new_target
	health = max_health
	state = State.CHASE
	_timer = 0.0
	_attack_cd = 0.0
	_knockback = Vector3.ZERO
	velocity = Vector3.ZERO
	_active = true
	visible = true
	collision_layer = 4    # слой 3 "Enemy"
	collision_mask = 7     # World + Player + Enemy
	_collision.set_deferred("disabled", false)
	respawned.emit()


func deactivate() -> void:
	_active = false
	state = State.DEAD
	target = null
	visible = false
	velocity = Vector3.ZERO
	_knockback = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	_collision.set_deferred("disabled", true)
	# Убираем далеко вниз, чтобы выключенное тело не мешало запросам формы
	global_position = Vector3(0.0, -100.0, 0.0)


func is_alive() -> bool:
	return _active and state != State.DEAD


# ------------------------------------------------------------------
# Вспомогательное
# ------------------------------------------------------------------

func _face(dir: Vector3, delta: float) -> void:
	var desired := atan2(-dir.x, -dir.z)
	# Ручной доворот вместо rotate_toward() - совместимо со всеми Godot 4.x
	var diff := wrapf(desired - rotation.y, -PI, PI)
	var step := deg_to_rad(turn_speed_deg) * delta
	rotation.y += clampf(diff, -step, step)


func _decelerate(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)


## ПОДВОХ, стоивший отладки: раньше здесь было "velocity += _knockback"
## каждый кадр, пока импульс затухает. Прибавка к скорости кадр за кадром -
## это не импульс, а постоянное ускорение: отброс раздувался лавинообразно
## (при knockback = 3 зомби улетал на 8.6 метра вместо полуметра).
## Теперь _knockback ЗАДАЁТ горизонтальную скорость, а не добавляется к ней.
func _apply_knockback(delta: float) -> void:
	if _knockback.length_squared() < 0.0001:
		_knockback = Vector3.ZERO
		return
	velocity.x = _knockback.x
	velocity.z = _knockback.z
	_knockback = _knockback.move_toward(Vector3.ZERO, knockback_damping * delta)


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	else:
		velocity.y = 0.0

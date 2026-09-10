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
signal hit_reaction(local_direction: Vector3, heavy: bool)
signal attack_started()
signal attack_contact()

enum State { IDLE, CHASE, WINDUP, RECOVER, STAGGER, DEAD, ACTIVE_HIT }
const CombatClock := preload("res://scripts/CombatAnimation.gd")

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
@export var attack_active_time := 0.14
@export var attack_arc_deg := 100.0
@export_range(0.1, 4.0) var attack_playback_speed := 1.0

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
var retiring := false
var combat_animation: CombatClock
var attack_side := 1.0
var attack_serial := 0
var _next_attack_side := 1.0
var _hitbox_enabled := false
var _attack_landed := false
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
	combat_animation = CombatClock.new()
	add_child(combat_animation)
	combat_animation.configure(attack_windup, attack_active_time, attack_recover)
	add_to_group("combat_telegraph")


func _physics_process(delta: float) -> void:
	if not _active or state == State.DEAD:
		return

	_attack_cd = maxf(0.0, _attack_cd - delta * effective_attack_speed())

	if not is_instance_valid(target) or not target.is_alive():
		if state != State.STAGGER:
			_cancel_attack()
			state = State.IDLE
	elif state == State.IDLE:
		state = State.CHASE

	match state:
		State.CHASE:
			_state_chase(delta)
		State.WINDUP:
			_state_windup(delta)
		State.ACTIVE_HIT, State.RECOVER:
			_decelerate(delta)
		State.STAGGER:
			_state_timed(delta, State.CHASE)
		State.IDLE:
			_decelerate(delta)
	combat_animation.step(delta, effective_attack_speed())
	if _hitbox_enabled:
		_sample_hitbox()
	if combat_animation.running:
		var end := combat_animation.windup_end if state == State.WINDUP else (combat_animation.active_end if state == State.ACTIVE_HIT else 1.0)
		_timer = maxf(0, (end - combat_animation.cursor) * combat_animation.duration)

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
		_begin_attack()
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
	if to_target.length_squared() > 0.0001 and combat_animation.phase_progress(0, combat_animation.windup_end) < 0.65:
		_face(to_target.normalized(), delta * 0.5)


func effective_attack_speed() -> float:
	# Even a buffed runner must leave at least 0.3 seconds to read a telegraph.
	return clampf(attack_playback_speed, 0.1, maxf(attack_windup / 0.3, 0.1))


func _begin_attack() -> void:
	attack_serial += 1
	state = State.WINDUP
	_timer = attack_windup
	attack_side = _next_attack_side
	_next_attack_side *= -1.0
	_attack_landed = false
	_hitbox_enabled = false
	combat_animation.configure(attack_windup, attack_active_time, attack_recover)
	combat_animation.begin()
	attack_started.emit()


func EnableHitbox() -> void:
	if state != State.WINDUP or not is_alive():
		return
	state = State.ACTIVE_HIT
	_hitbox_enabled = true
	_attack_cd = attack_cooldown
	attack_contact.emit()
	_sample_hitbox()


func _sample_hitbox() -> void:
	if _attack_landed or not is_instance_valid(target) or not target.is_alive():
		return
	var offset: Vector3 = target.global_position - global_position
	offset.y = 0.0
	if offset.length() > attack_range * 1.15:
		return
	if offset.length_squared() > 0.001 and (-global_basis.z).angle_to(offset.normalized()) > deg_to_rad(attack_arc_deg * 0.5):
		return
	_attack_landed = true
	target.take_damage(attack_damage, global_position, self)
	hit_player.emit(attack_damage)


func DisableHitbox() -> void:
	if state != State.ACTIVE_HIT:
		return
	_hitbox_enabled = false
	state = State.RECOVER


func ResetComboWindow() -> void:
	pass # Enemies have a cooldown rather than a player input buffer.


func FinishAttack() -> void:
	if state != State.RECOVER:
		return
	_cancel_attack()
	state = State.CHASE if is_instance_valid(target) and target.is_alive() else State.IDLE


func _cancel_attack() -> void:
	if combat_animation != null:
		combat_animation.cancel()
	_hitbox_enabled = false


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
	var hit_dir := global_position - from_position
	hit_dir.y = 0.0
	hit_reaction.emit(global_basis.inverse() * hit_dir.normalized(), knockback >= 2.5 or stun > 0.5)

	if knockback > 0.0:
		var dir := global_position - from_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			_knockback = dir.normalized() * knockback

	if stun > 0.0 or state == State.WINDUP:
		stagger(maxf(stun, 0.24), from_position)

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

	var remaining := _timer if state == State.STAGGER else 0.0
	_cancel_attack()
	state = State.STAGGER
	_timer = maxf(remaining, duration)
	_attack_cd = maxf(_attack_cd, duration)
	var hit_dir := global_position - from_position
	hit_dir.y = 0.0
	hit_reaction.emit(global_basis.inverse() * hit_dir.normalized(), duration >= 0.5)

	if knockback > 0.0:
		var dir := global_position - from_position
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			_knockback = dir.normalized() * knockback


func _die() -> void:
	_cancel_attack()
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
			attack_windup = 0.35
			health_mult = 0.5
			speed_mult = 1.75
			damage_mult = 0.65
			cooldown_mult = 0.75
		Variant.BRUTE:
			attack_windup = 0.50
			health_mult = 2.6
			speed_mult = 0.62
			damage_mult = 1.9
			cooldown_mult = 1.25
		_:
			attack_windup = 0.45

	max_health = _base_health * health_mult * _threat_health_scale
	move_speed = _base_speed * speed_mult * _threat_speed_scale
	attack_damage = _base_damage * damage_mult * _threat_damage_scale
	attack_cooldown = _base_cooldown * cooldown_mult * _threat_cooldown_scale


func activate(spawn_transform: Transform3D, new_target: Node3D) -> void:
	retiring = false
	_cancel_attack()
	_attack_landed = false
	_next_attack_side = 1.0
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
	retiring = false
	_cancel_attack()
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


func retire_with_animation() -> void:
	if state != State.DEAD:
		return
	_cancel_attack()
	retiring = true
	_active = false
	collision_layer = 0
	collision_mask = 0
	_collision.set_deferred("disabled", true)


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

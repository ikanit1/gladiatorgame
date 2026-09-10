extends Node3D

const PV := preload("res://scripts/ProceduralVisuals.gd")

## ВИЗУАЛ ГЛАДИАТОРА - процедурная анимация без AnimationPlayer и без Tween.
##
## Почему так:
##  * ни одной аллокации за кадр (Tween создаёт объекты на каждый вызов);
##  * ни одного ключевого кадра для поддержки - поза целиком вычисляется
##    из состояния тела, значит визуал не может рассинхронизироваться с механикой;
##  * вся ветка отключается одним process_mode = DISABLED при headless-обучении.
##
## Скрипт ТОЛЬКО читает состояние Gladiator.gd и никогда его не меняет.
## Ничего из этого файла не влияет на наблюдения, награды и хитбоксы.

@export_group("Ходьба")
@export var walk_cycle_speed: float = 2.6      ## скорость цикла шага на м/с
@export var leg_swing_deg: float = 38.0
@export var arm_swing_deg: float = 22.0
@export var bob_height: float = 0.035

@export_group("Реакции")
@export var flash_color: Color = Color(1.0, 0.25, 0.2)
@export var block_flash_color: Color = Color(0.55, 0.8, 1.0)
@export var flash_time: float = 0.22
@export var attack_anim_time: float = 0.42
@export var kick_anim_time: float = 0.38
@export var secondary_motion: float = 1.0 ## интенсивность ткани и дыхания

# Базовые позы (градусы). Всё, что не анимируется, живёт здесь, а не в .tscn -
# так позу можно править в одном месте, не трогая иерархию сцены.
const REST_ARM_R := Vector3(0.0, 0.0, -7.0)
const REST_ARM_L := Vector3(0.0, 0.0, 7.0)
const REST_SWORD := Vector3(-160.0, 0.0, 0.0)   ## клинок опущен вниз-вперёд
const BLOCK_ARM_L := Vector3(78.0, 0.0, 26.0)   ## щит перед грудью

@onready var _pivot: Node3D = $Body
@onready var _arm_r: Node3D = $Body/ArmR
@onready var _arm_l: Node3D = $Body/ArmL
@onready var _leg_l: Node3D = $Body/LegL
@onready var _leg_r: Node3D = $Body/LegR
@onready var _head: Node3D = $Body/Head
@onready var _torso: Node3D = $Body/Torso
@onready var _sword: Node3D = $Body/ArmR/Sword
@onready var _shield: Node3D = $Body/ArmL/Shield
@onready var _blade: MeshInstance3D = $Body/ArmR/Sword/Blade
@onready var _sfx: SfxPlayer = $Sfx

const SND_SWING := preload("res://audio/sword_swing.wav")
const SND_HIT := preload("res://audio/sword_hit.wav")
const SND_KICK := preload("res://audio/kick.wav")
const SND_BLOCK := preload("res://audio/shield_block.wav")
const SND_GUARD_BREAK := preload("res://audio/guard_break.wav")
const SND_HURT := preload("res://audio/player_hurt.wav")
const SND_DIE := preload("res://audio/player_die.wav")
const SND_STEP := preload("res://audio/footstep.wav")

var _g: Gladiator

var _walk_phase: float = 0.0
var _attack_t: float = -1.0    ## -1 = анимация не идёт
var _kick_t: float = -1.0
var _block_amt: float = 0.0    ## сглаженное 0..1
var _flash: float = 0.0
var _death_t: float = 0.0
var _stagger_phase: float = 0.0
var _step_sign: float = 1.0     ## для определения момента шага
var _idle_phase: float = 0.0
var _hurt_t: float = 0.0

var _body_meshes: Array[MeshInstance3D] = []
var _flash_mat: StandardMaterial3D
var _blade_mat: StandardMaterial3D
var _cape_root: Node3D
var _cape_a: Node3D
var _cape_b: Node3D
var _cape_c: Node3D
var _cape_d: Node3D
var _chest_gem: MeshInstance3D
var _slash_trail: MeshInstance3D
var _glow_mat: StandardMaterial3D


func _ready() -> void:
	_g = get_parent() as Gladiator
	if _g == null:
		push_error("GladiatorVisuals должен быть дочерней нодой Gladiator")
		set_process(false)
		return

	_create_signature_details()
	_collect_meshes(self)
	_body_meshes.erase(_blade)

	# Один общий overlay-материал на весь визуал: вспышка = смена его альфы.
	# Дешевле, чем дублировать albedo каждого материала.
	_flash_mat = _make_overlay(flash_color)
	_blade_mat = _make_overlay(Color(1.0, 1.0, 0.96))

	_g.attack_started.connect(_on_attack_started)
	_g.dealt_damage.connect(_on_dealt_damage)
	_g.took_damage.connect(_on_took_damage)
	_g.damage_blocked.connect(_on_damage_blocked)
	_g.guard_broken.connect(_on_guard_broken)
	_g.respawned.connect(_on_respawned)
	_g.revived.connect(_on_revived)

	_apply_rest_pose()


## Добавляет персонажу читаемый силуэт: плащ из трёх сегментов, светящийся
## визор/нагрудный камень, руну щита и отдельный след клинка. Это создаётся
## один раз и не требует новых узлов во время боя.
func _create_signature_details() -> void:
	var bronze := PV.material(Color(0.72, 0.32, 0.08), 0.82, 0.25)
	var dark := PV.material(Color(0.035, 0.045, 0.06), 0.65, 0.28)
	_glow_mat = PV.material(Color(1.0, 0.23, 0.035), 0.1, 0.22,
		Color(1.0, 0.08, 0.015), 5.0)
	var cloth := PV.material(Color(0.42, 0.045, 0.06), 0.0, 0.9)
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Острые плечевые накладки поверх старых примитивных паулдронов.
	PV.sphere(_arm_r, "ShoulderBoss", 0.105,
		Vector3(0.02, 0.06, 0.0), bronze, 0.16)
	PV.sphere(_arm_l, "ShoulderBoss", 0.105,
		Vector3(-0.02, 0.06, 0.0), bronze, 0.16)
	PV.box(_head, "VisorGlow", Vector3(0.18, 0.026, 0.018),
		Vector3(0.0, -0.025, -0.145), _glow_mat)
	_chest_gem = PV.sphere(_torso, "ChestGem", 0.065,
		Vector3(0.0, 0.02, -0.18), _glow_mat, 0.10)

	_cape_root = Node3D.new()
	_cape_root.name = "TatteredCape"
	_cape_root.position = Vector3(0.0, 1.2, 0.25)
	_pivot.add_child(_cape_root)
	_cape_a = _cape_segment("CapeTop", Vector3(0.0, 0.0, 0.0),
		Vector3(0.62, 0.48, 0.0), cloth)
	_cape_b = _cape_segment("CapeMid", Vector3(0.0, -0.36, 0.018),
		Vector3(0.74, 0.52, 0.0), cloth)
	_cape_c = _cape_segment("CapeTail", Vector3(0.0, -0.73, 0.04),
		Vector3(0.84, 0.46, 0.0), cloth)
	_cape_d = _cape_segment("CapeTear", Vector3(0.0, -0.98, 0.065),
		Vector3(0.9, 0.38, 0.0), cloth)
	# Металлическая застёжка плаща.
	PV.torus(_cape_root, "CapeClasp", 0.055, 0.075,
		Vector3(0.0, 0.02, -0.025), bronze)

	# Руна на щите и светящийся след, который появляется только во время удара.
	PV.torus(_shield, "ShieldRune", 0.15, 0.175,
		Vector3(0.0, 0.0, -0.045), _glow_mat)
	_slash_trail = PV.box(_sword, "SlashTrail",
		Vector3(0.035, 0.72, 0.025), Vector3(0.0, 0.43, 0.05), _glow_mat)
	_slash_trail.visible = false
	# Тонкое навершие добавляет контраст оружию в дальнем плане.
	PV.sphere(_sword, "SwordPommelGlow", 0.035,
		Vector3(0.0, -0.13, 0.0), dark, 0.06)


func _cape_segment(segment_name: String, pos: Vector3, size: Vector3,
		material: Material) -> Node3D:
	var segment := Node3D.new()
	segment.name = segment_name
	segment.position = pos
	_cape_root.add_child(segment)
	PV.quad(segment, "Cloth", Vector2(size.x, size.y), Vector3.ZERO,
		material as StandardMaterial3D)
	return segment


func _process(delta: float) -> void:
	if _g == null:
		return

	_update_timers(delta)

	if not _g.is_alive():
		_animate_death(delta)
		return

	_animate_locomotion(delta)
	_animate_block(delta)
	_animate_attack()
	_animate_kick()
	_animate_stagger(delta)
	_animate_secondary_motion(delta)
	_apply_flash()


# ------------------------------------------------------------------
# Поза
# ------------------------------------------------------------------

func _apply_rest_pose() -> void:
	_arm_r.rotation_degrees = REST_ARM_R
	_arm_l.rotation_degrees = REST_ARM_L
	_sword.rotation_degrees = REST_SWORD
	_leg_l.rotation = Vector3.ZERO
	_leg_r.rotation = Vector3.ZERO
	_pivot.rotation = Vector3.ZERO
	_pivot.position = Vector3.ZERO
	_head.rotation = Vector3.ZERO
	_torso.rotation = Vector3.ZERO
	if _cape_a != null:
		_cape_root.rotation = Vector3.ZERO
		_cape_a.rotation = Vector3.ZERO
		_cape_b.rotation = Vector3.ZERO
		_cape_c.rotation = Vector3.ZERO
		_cape_d.rotation = Vector3.ZERO
	if _slash_trail != null:
		_slash_trail.visible = false
	_sync_shield()


## Щит всегда стоит плоскостью вперёд, как бы ни была повёрнута рука:
## компенсируем поворот плеча, иначе при блоке щит "ложится" горизонтально.
func _sync_shield() -> void:
	_shield.rotation.x = deg_to_rad(90.0) - _arm_l.rotation.x
	_shield.rotation.z = -_arm_l.rotation.z


func _update_timers(delta: float) -> void:
	if _attack_t >= 0.0:
		_attack_t += delta
		if _attack_t > attack_anim_time:
			_attack_t = -1.0
	if _kick_t >= 0.0:
		_kick_t += delta
		if _kick_t > kick_anim_time:
			_kick_t = -1.0
	_flash = maxf(0.0, _flash - delta)
	_hurt_t = maxf(0.0, _hurt_t - delta)
	_idle_phase += delta * (1.4 + Vector2(_g.velocity.x, _g.velocity.z).length() * 0.25)


# ------------------------------------------------------------------
# Анимации
# ------------------------------------------------------------------

func _animate_locomotion(delta: float) -> void:
	var speed := Vector2(_g.velocity.x, _g.velocity.z).length()
	var moving := speed > 0.15

	if moving:
		_walk_phase += delta * speed * walk_cycle_speed

	# При остановке амплитуда сама уходит в ноль вместе со скоростью,
	# поэтому фазу обрывать не нужно - ноги сводятся плавно.
	var amp := clampf(speed / maxf(_g.move_speed, 0.001), 0.0, 1.0)
	var swing := sin(_walk_phase) * deg_to_rad(leg_swing_deg) * amp

	_leg_l.rotation.x = swing
	_leg_r.rotation.x = -swing
	_pivot.position.y = absf(sin(_walk_phase)) * bob_height * amp
	_torso.rotation_degrees.z = sin(_walk_phase * 0.5) * 2.5 * amp
	_head.rotation_degrees.y = sin(_walk_phase * 0.35) * 3.0 * amp

	# Шаг звучит на смене знака синуса - ровно когда нога ставится на песок
	if moving:
		var sign_now := signf(sin(_walk_phase))
		if sign_now != _step_sign and sign_now != 0.0:
			_step_sign = sign_now
			_sfx.play(SND_STEP, -12.0, 0.2)

	# Противоход руки с мечом - только когда она свободна
	if _attack_t < 0.0:
		_arm_r.rotation.x = -swing * (arm_swing_deg / maxf(leg_swing_deg, 0.001))


func _animate_block(delta: float) -> void:
	var want := 1.0 if _g.is_blocking else 0.0
	_block_amt = move_toward(_block_amt, want, delta * 7.0)

	var rest := REST_ARM_L
	var target := rest.lerp(BLOCK_ARM_L, _block_amt)
	_arm_l.rotation_degrees = target

	# Корпус слегка доворачивается за щитом
	_pivot.rotation.y = deg_to_rad(-10.0) * _block_amt
	_sync_shield()


func _animate_attack() -> void:
	if _attack_t < 0.0:
		_sword.rotation_degrees = REST_SWORD
		return

	var t := _attack_t / attack_anim_time

	# Три фазы: замах назад-вверх -> резкий удар -> возврат
	var arm_deg: float
	var sword_deg: float
	var side_deg: float     # отвод руки вбок: без него клинок режет голову
	if t < 0.3:
		var k := t / 0.3
		arm_deg = lerpf(0.0, -92.0, ease_out(k))
		sword_deg = lerpf(REST_SWORD.x, -212.0, ease_out(k))
		side_deg = lerpf(REST_ARM_R.z, -42.0, ease_out(k))
	elif t < 0.55:
		var k := (t - 0.3) / 0.25
		arm_deg = lerpf(-92.0, 68.0, ease_in(k))
		sword_deg = lerpf(-212.0, -100.0, ease_in(k))
		side_deg = lerpf(-42.0, -14.0, ease_in(k))
	else:
		var k := (t - 0.55) / 0.45
		arm_deg = lerpf(68.0, 0.0, k)
		sword_deg = lerpf(-100.0, REST_SWORD.x, k)
		side_deg = lerpf(-14.0, REST_ARM_R.z, k)

	_arm_r.rotation_degrees = Vector3(arm_deg, 0.0, side_deg)
	_sword.rotation_degrees = Vector3(sword_deg, 0.0, 0.0)

	# Корпус доворачивается в удар - придаёт замаху вес
	_pivot.rotation.y += deg_to_rad(18.0) * sin(t * PI)
	if _slash_trail != null:
		_slash_trail.visible = true
		_slash_trail.scale = Vector3(1.0 + sin(t * PI) * 0.8, 1.0, 1.0)


func _animate_kick() -> void:
	if _kick_t < 0.0:
		_pivot.rotation.x = 0.0
		return

	var t := _kick_t / kick_anim_time
	var deg := sin(t * PI) * 88.0

	_leg_r.rotation.x = deg_to_rad(deg)
	_leg_l.rotation.x = deg_to_rad(-deg * 0.15)
	# Отклоняемся назад для равновесия
	_pivot.rotation.x = deg_to_rad(-deg * 0.12)


func _animate_secondary_motion(delta: float) -> void:
	# Небольшое дыхание и инерция ткани делают idle живым, но не меняют хитбокс.
	var breath := sin(_idle_phase) * 0.012 * secondary_motion
	_torso.scale = Vector3(1.0 + breath, 1.0 - breath * 0.45, 1.0 + breath)
	if _chest_gem != null:
		_chest_gem.scale = Vector3.ONE * (1.0 + absf(breath) * 8.0)

	var speed := Vector2(_g.velocity.x, _g.velocity.z).length()
	var wind := clampf(speed / maxf(_g.move_speed, 0.001), 0.0, 1.0)
	# Переводим скорость в локальные координаты: плащ должен развеваться
	# именно за движением гладиатора, а не просто вращаться по синусоиде.
	var local_velocity := _g.global_transform.basis.inverse() * _g.velocity
	var forward_speed := clampf(-local_velocity.z / maxf(_g.move_speed, 0.001), -1.0, 1.0)
	var side_speed := clampf(local_velocity.x / maxf(_g.move_speed, 0.001), -1.0, 1.0)
	var air_flow := clampf(absf(forward_speed) + absf(side_speed) * 0.55, 0.0, 1.0)
	var drag := deg_to_rad(4.0 + maxf(forward_speed, 0.0) * 44.0 + air_flow * 8.0)
	var ripple := sin(_idle_phase * 2.2 + _walk_phase * 0.45) * \
		deg_to_rad(4.0 + air_flow * 14.0)
	var side_wave := deg_to_rad(side_speed * 15.0)
	_cape_root.rotation_degrees.z = side_speed * 6.0
	_cape_root.rotation_degrees.y = -side_speed * 8.0
	if _cape_a != null:
		_cape_a.rotation_degrees.x = rad_to_deg(drag * 0.28 + ripple * 0.25)
		_cape_a.rotation_degrees.z = rad_to_deg(side_wave * 0.25)
		_cape_b.rotation_degrees.x = rad_to_deg(drag * 0.72 + ripple)
		_cape_b.rotation_degrees.z = rad_to_deg(side_wave * 0.7 - ripple * 0.2)
		_cape_c.rotation_degrees.x = rad_to_deg(drag * 1.18 + ripple * 1.3)
		_cape_c.rotation_degrees.z = rad_to_deg(side_wave * 1.2 + ripple * 0.3)
		_cape_d.rotation_degrees.x = rad_to_deg(drag * 1.62 + ripple * 1.55)
		_cape_d.rotation_degrees.z = rad_to_deg(side_wave * 1.55 - ripple * 0.4)

	if _hurt_t > 0.0:
		_pivot.rotation.z += deg_to_rad(5.0) * sin(_hurt_t * 28.0)

	# След клинка исчезает вместе с атакой, чтобы не оставаться включённым
	# после возврата в idle.
	if _attack_t < 0.0 and _slash_trail != null:
		_slash_trail.visible = false


func _animate_stagger(delta: float) -> void:
	if _g.stun_time <= 0.0:
		_stagger_phase = 0.0
		_pivot.rotation.z = 0.0
		_head.rotation.z = 0.0
		return

	_stagger_phase += delta * 22.0
	_pivot.rotation.z = deg_to_rad(9.0) * sin(_stagger_phase)
	_head.rotation.z = deg_to_rad(-6.0) * sin(_stagger_phase * 0.7)
	# Щит выбит - рука падает
	_arm_l.rotation_degrees = REST_ARM_L
	_sync_shield()


func _animate_death(delta: float) -> void:
	if _death_t <= 0.0:
		_sfx.play(SND_DIE, 0.0)
	_death_t = minf(_death_t + delta, 1.0)
	var k := ease_out(_death_t)

	_pivot.rotation.x = deg_to_rad(88.0) * k
	_pivot.position.y = -0.45 * k
	_arm_r.rotation_degrees = REST_ARM_R.lerp(Vector3(-40.0, 0.0, -25.0), k)
	_arm_l.rotation_degrees = REST_ARM_L.lerp(Vector3(-30.0, 0.0, 25.0), k)
	_sync_shield()
	_apply_flash()


func _apply_flash() -> void:
	var a := _flash / maxf(flash_time, 0.001)
	if a <= 0.0:
		if _flash_mat.albedo_color.a > 0.0:
			_flash_mat.albedo_color.a = 0.0
			_set_overlay(null)
		return

	_flash_mat.albedo_color.a = a * 0.38
	_set_overlay(_flash_mat)


# ------------------------------------------------------------------
# Сигналы механики
# ------------------------------------------------------------------

func _on_attack_started(attack_type: int) -> void:
	if attack_type == Gladiator.AttackType.SWORD:
		_attack_t = 0.0
		_sfx.play(SND_SWING, -6.0)
		_blade_mat.albedo_color.a = 0.3
		_blade.material_overlay = _blade_mat
		# Гасим свечение клинка отдельным лёгким таймером - меша всего один
		get_tree().create_timer(0.18).timeout.connect(func():
			if is_instance_valid(_blade):
				_blade.material_overlay = null)
	else:
		_kick_t = 0.0
		_sfx.play(SND_KICK, -3.0)


func _on_dealt_damage(_amount: float, _target: Node3D, _type: int) -> void:
	_sfx.play(SND_HIT, -2.0)


func _on_took_damage(_amount: float, blocked: bool) -> void:
	_flash = flash_time
	_hurt_t = 0.18
	_flash_mat.albedo_color = block_flash_color if blocked else flash_color
	if not blocked:
		_sfx.play(SND_HURT, -3.0)


func _on_damage_blocked(_absorbed: float) -> void:
	_flash = flash_time
	_flash_mat.albedo_color = block_flash_color
	_sfx.play(SND_BLOCK, 1.0)


func _on_guard_broken() -> void:
	_flash = flash_time
	_flash_mat.albedo_color = Color(1.0, 0.9, 0.3)
	_sfx.play(SND_GUARD_BREAK, 1.0)


## Подъём - это не респавн: поза сбрасывается, а счётчики боя нет.
func _on_revived(_hp: float) -> void:
	_death_t = 0.0
	_apply_rest_pose()


func _on_respawned() -> void:
	_death_t = 0.0
	_attack_t = -1.0
	_kick_t = -1.0
	_block_amt = 0.0
	_flash = 0.0
	_walk_phase = 0.0
	_idle_phase = 0.0
	_hurt_t = 0.0
	_stagger_phase = 0.0
	_set_overlay(null)
	_blade.material_overlay = null
	_apply_rest_pose()


# ------------------------------------------------------------------
# Вспомогательное
# ------------------------------------------------------------------

func _collect_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_body_meshes.append(child)
		_collect_meshes(child)


func _set_overlay(mat: Material) -> void:
	for m in _body_meshes:
		m.material_overlay = mat


func _make_overlay(c: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(c.r, c.g, c.b, 0.0)
	return mat


static func ease_out(k: float) -> float:
	return 1.0 - pow(1.0 - clampf(k, 0.0, 1.0), 3.0)


static func ease_in(k: float) -> float:
	return pow(clampf(k, 0.0, 1.0), 2.2)

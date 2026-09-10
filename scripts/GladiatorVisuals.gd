extends Node3D

const PV := preload("res://scripts/ProceduralVisuals.gd")
const Geometry := preload("res://scripts/CharacterGeometry.gd")
const Motion := preload("res://scripts/CharacterMotion.gd")

## Процедурные суставы читают общий курсор CombatAnimation у тела.
## Нижний слой ведёт ноги; верхний добавляет атаку, щит и реакции.
## Visuals можно отключить при обучении: события урона живут у тела.
##
## Скрипт ТОЛЬКО читает состояние Gladiator.gd и никогда его не меняет.
## Ничего из этого файла не влияет на наблюдения, награды и хитбоксы.

@export_group("Ходьба")
@export var walk_cycle_speed: float = 2.6      ## скорость цикла шага на м/с
@export var stride_length: float = 0.25
@export var arm_swing_deg: float = 13.0
@export var bob_height: float = 0.012

@export_group("Реакции")
@export var flash_color: Color = Color(1.0, 0.25, 0.2)
@export var block_flash_color: Color = Color(0.55, 0.8, 1.0)
@export var flash_time: float = 0.22
@export var attack_anim_time: float = 0.42
@export var kick_anim_time: float = 0.38
@export var secondary_motion: float = 1.0 ## интенсивность ткани и дыхания

# Базовые позы (градусы). Всё, что не анимируется, живёт здесь, а не в .tscn -
# так позу можно править в одном месте, не трогая иерархию сцены.
const REST_ARM_R := Vector3(0.0, 0.0, 7.0)
const REST_ARM_L := Vector3(0.0, 0.0, -7.0)
const REST_SWORD := Vector3(-160.0, 0.0, 0.0)   ## клинок опущен вниз-вперёд
const BLOCK_ARM_L := Vector3(48.0, -12.0, 18.0)   ## щит перед грудью

enum SwordSwing { DIAGONAL, SIDE, BACKHAND, OVERHEAD }

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

var _elbow_r: Node3D
var _elbow_l: Node3D
var _knee_r: Node3D
var _knee_l: Node3D
var _move_amount := 0.0
var _local_velocity := Vector3.ZERO
var _wrist_degrees := REST_SWORD
var _g: Gladiator

var _walk_phase: float = 0.0
var _attack_t: float = -1.0    ## -1 = анимация не идёт
var _sword_swing: SwordSwing = SwordSwing.DIAGONAL
var _next_sword_swing := 0
var _kick_t: float = -1.0
var _block_amt: float = 0.0    ## сглаженное 0..1
var _flash: float = 0.0
var _death_t: float = 0.0
var _stagger_phase: float = 0.0
var _step_sign: float = 1.0     ## для определения момента шага
var _idle_phase: float = 0.0
var _hurt_t: float = 0.0
var _hurt_direction := Vector3.ZERO
var _hurt_heavy := false
var _guard_basis := Basis.IDENTITY
var _guard_yaw := 0.0
var _guard_pitch := 0.0
var _lean := Vector3.ZERO
var _last_velocity := Vector3.ZERO
var _attack_entry_arm := REST_ARM_R
var _attack_entry_elbow := 12.0
var _attack_entry_wrist := REST_SWORD
var _recoil_arm := REST_ARM_R
var _death_arm_r := REST_ARM_R
var _death_arm_l := REST_ARM_L
var _death_rotation := Vector3.ZERO

var _body_meshes: Array[MeshInstance3D] = []
var _flash_mat: StandardMaterial3D
var _cape_root: Node3D
var _cape_a: Node3D
var _cape_b: Node3D
var _cape_c: Node3D
var _cape_d: Node3D
var _slash_trail: MeshInstance3D


func _ready() -> void:
	_g = get_parent() as Gladiator
	if _g == null:
		push_error("GladiatorVisuals должен быть дочерней нодой Gladiator")
		set_process(false)
		return

	Geometry.gladiator(self)
	_elbow_r = _arm_r.get_node("Elbow")
	_elbow_l = _arm_l.get_node("Elbow")
	_knee_r = _leg_r.get_node("Knee")
	_knee_l = _leg_l.get_node("Knee")
	_create_signature_details()
	_collect_meshes(self)
	_body_meshes.erase(_blade)

	# Один общий overlay-материал на весь визуал: вспышка = смена его альфы.
	# Дешевле, чем дублировать albedo каждого материала.
	_flash_mat = _make_overlay(flash_color)

	_g.attack_started.connect(_on_attack_started)
	_g.dealt_damage.connect(_on_dealt_damage)
	_g.took_damage.connect(_on_took_damage)
	_g.damage_blocked.connect(_on_damage_blocked)
	_g.guard_broken.connect(_on_guard_broken)
	_g.respawned.connect(_on_respawned)
	_g.revived.connect(_on_revived)
	_g.attack_contact.connect(_on_attack_contact)
	_g.hit_reaction.connect(_on_hit_reaction)

	_apply_rest_pose()


## Четыре связанных сегмента плаща и короткий след только на взмахе.
func _create_signature_details() -> void:
	var cloth := Geometry.material("crimson", Color("642731"), 0.0, 0.94)
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cape_root = Geometry.joint(_pivot, "TatteredCape", Vector3(0.0, 1.49, 0.17))
	_cape_a = Geometry.joint(_cape_root, "CapeTop", Vector3.ZERO)
	Geometry.cloth(_cape_a, "Cloth", 0.49, 0.24, cloth, 1.1)
	_cape_b = Geometry.joint(_cape_a, "CapeMid", Vector3(0, -0.24, 0.035))
	Geometry.cloth(_cape_b, "Cloth", 0.539, 0.25, cloth, 1.08)
	_cape_c = Geometry.joint(_cape_b, "CapeTail", Vector3(0, -0.25, 0.035))
	Geometry.cloth(_cape_c, "Cloth", 0.582, 0.25, cloth, 1.04)
	_cape_d = Geometry.joint(_cape_c, "CapeTear", Vector3(0, -0.25, 0.035))
	Geometry.cloth(_cape_d, "Cloth", 0.605, 0.24, cloth, 0.9, true)
	var trail_mat := PV.material(Color(0.85, 0.87, 0.75, 0.18), 0.0, 0.7)
	trail_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_slash_trail = PV.box(_sword, "SlashTrail", Vector3(0.09, 0.45, 0.008),
		Vector3(0.0, 0.39, 0.0), trail_mat)
	_slash_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_slash_trail.visible = false


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
	_sync_equipment()
	_apply_flash()


# ------------------------------------------------------------------
# Поза
# ------------------------------------------------------------------

func _apply_rest_pose() -> void:
	_arm_r.rotation_degrees = REST_ARM_R
	_arm_l.rotation_degrees = REST_ARM_L
	_elbow_r.rotation_degrees = Vector3(12, 0, 0)
	_elbow_l.rotation_degrees = Vector3(18, 0, 0)
	_knee_r.rotation = Vector3.ZERO
	_knee_l.rotation = Vector3.ZERO
	_knee_r.get_node("Foot").rotation = Vector3.ZERO
	_knee_l.get_node("Foot").rotation = Vector3.ZERO
	_wrist_degrees = REST_SWORD
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
	_sync_equipment()


## Щит всегда стоит плоскостью вперёд, как бы ни была повёрнута рука:
## компенсируем поворот плеча, иначе при блоке щит "ложится" горизонтально.
func _sync_shield() -> void:
	# Cancel the complete arm rotation: subtracting Euler X/Z angles breaks
	# when the raised arm rotates around both axes during a block.
	# ShieldModel's scene transform points its face down local Y;
	# Rx(90) faces it forward and keeps the imported decoration upright.
	_shield.basis = _arm_l.basis.inverse() * _guard_basis * Basis(Vector3.RIGHT, PI * 0.5)


func _update_timers(delta: float) -> void:
	# Both pose and hit-window events read the same animation cursor.
	_attack_t = -1.0
	_kick_t = -1.0
	if _g.combat_animation != null and _g.combat_animation.running:
		if _g.current_attack == Gladiator.AttackType.SWORD:
			_attack_t = _g.combat_animation.cursor * attack_anim_time
		else:
			_kick_t = _g.combat_animation.cursor * kick_anim_time
	_flash = maxf(0.0, _flash - delta)
	_hurt_t = maxf(0.0, _hurt_t - delta)
	_idle_phase += delta * (1.4 + Vector2(_g.velocity.x, _g.velocity.z).length() * 0.25)


# ------------------------------------------------------------------
# Анимации
# ------------------------------------------------------------------

func _animate_locomotion(delta: float) -> void:
	var local := _g.global_basis.orthonormalized().inverse() * _g.velocity
	local.y = 0.0
	if _g.stun_time > 0.0:
		local = Vector3.ZERO
	var accel := (local - _last_velocity) / maxf(delta, 0.001)
	_last_velocity = local
	_lean = _lean.lerp(Vector3(clampf(-local.z * 0.8 - accel.z * 0.08, -5, 6), 0,
		clampf(-local.x * 0.65 - accel.x * 0.06, -5, 5)), Motion.weight(delta, 7.0))
	_local_velocity = _local_velocity.lerp(local, Motion.weight(delta))
	var speed := _local_velocity.length()
	_move_amount = lerpf(_move_amount, clampf(speed / 3.8, 0.0, 1.0), Motion.weight(delta))
	if speed > 0.05:
		_walk_phase = fmod(_walk_phase + delta * speed * walk_cycle_speed, TAU)
	var direction := _local_velocity.normalized() if speed > 0.05 else Vector3.FORWARD
	_pivot.position.y = sin(_walk_phase * 2.0) * bob_height * _move_amount
	_pivot.rotation = Vector3.ZERO
	_torso.rotation_degrees = Vector3(_lean.x, sin(_walk_phase) * 3.0 * _move_amount, _lean.z)
	_head.rotation_degrees = Vector3(0, -sin(_walk_phase) * 2.0 * _move_amount, 0)
	Motion.leg(_leg_l, _knee_l, _walk_phase, _move_amount, direction, 0.43, 0.37, _pivot.position.y, 1.0, stride_length)
	Motion.leg(_leg_r, _knee_r, _walk_phase + PI, _move_amount, direction, 0.43, 0.37, _pivot.position.y, 1.0, stride_length)
	_arm_r.rotation_degrees = REST_ARM_R + Vector3(sin(_walk_phase) * arm_swing_deg * _move_amount, 0, 0)
	_elbow_r.rotation_degrees = Vector3(12.0 + 8.0 * _move_amount, 0, 0)
	_wrist_degrees = REST_SWORD
	if speed > 0.4:
		var sign_now := signf(sin(_walk_phase))
		if sign_now != _step_sign and sign_now != 0.0:
			_step_sign = sign_now
			_sfx.play(SND_STEP, -12.0, 0.2)


func _animate_block(delta: float) -> void:
	var want := 1.0 if _g.is_blocking and _g.stun_time <= 0.0 else 0.0
	_block_amt = lerpf(_block_amt, want, Motion.weight(delta, 18.0))
	_arm_l.rotation_degrees = REST_ARM_L.lerp(BLOCK_ARM_L, _block_amt)
	_elbow_l.rotation_degrees = Vector3(lerpf(18, 68, _block_amt), 0, 0)
	_torso.rotation.y += deg_to_rad(-7.0) * _block_amt
	var aim := _g.global_basis.inverse() * _g.guard_direction()
	var yaw := atan2(-aim.x, -aim.z)
	var pitch := 0.0
	if _g.intent_aim_direction.length_squared() > 0.001:
		pitch = clampf(asin(clampf(_g.intent_aim_direction.normalized().y, -1, 1)), -0.35, 0.35)
	_guard_yaw = lerp_angle(_guard_yaw, yaw * _block_amt, Motion.weight(delta, 16))
	_guard_pitch = lerpf(_guard_pitch, pitch * _block_amt, Motion.weight(delta, 16))
	_guard_basis = Basis.from_euler(Vector3(_guard_pitch, _guard_yaw, 0))
	var wrist_target := Vector3(0.23, 1.27, -0.39).rotated(Vector3.UP, _guard_yaw)
	wrist_target.y += sin(_guard_pitch) * 0.22
	Motion.arm(_arm_l, _elbow_l, wrist_target, Vector3(-0.5, 0, -1), _block_amt)
	_head.rotation_degrees.y += rad_to_deg(_guard_yaw) * 0.45


func _sync_equipment() -> void:
	# The weapon nodes keep their public scene paths; their grips follow wrists.
	_sword.position = _elbow_r.position + _elbow_r.basis * Vector3(0, -0.335, -0.025)
	_sword.basis = _elbow_r.basis * Basis.from_euler(_wrist_degrees * PI / 180.0)
	# Offset toward the opponent in body space, independently of elbow bend.
	# Otherwise a raised forearm pushes the knuckles through the shield face.
	_shield.position = _elbow_l.position + _elbow_l.basis * Vector3(0, -0.335, -0.025) \
		+ _arm_l.basis.inverse() * (_guard_basis * Vector3(-0.01, 0.01, -0.14))
	_sync_shield()


func _animate_attack() -> void:
	if _attack_t < 0.0:
		_slash_trail.visible = false
		return
	var t := clampf(_attack_t / maxf(attack_anim_time, 0.01), 0, 1)
	# Anticipation -> contact -> follow-through -> locomotion. Contact is the
	# EnableHitbox key, so buffs and hit-stop cannot desynchronise the pose.
	var clock := _g.combat_animation
	var windup := Vector3(118, -52, 38)
	var start := Vector3(62, -32, 25)
	var follow := Vector3(35, 16, 24)
	var elbow_start := 38.0
	var elbow_follow := 18.0
	var wrist_start := Vector3(-155, 0, 0)
	var wrist_follow := Vector3(-125, 0, 0)
	var body_start := Vector3(0, -12, 0)
	var body_follow := Vector3(0, 12, 0)
	var contact_end: float = clock.active_end
	match _sword_swing:
		SwordSwing.SIDE:
			windup = Vector3(85, -75, 65)
			start = Vector3(72, -48, 48)
			follow = Vector3(54, 24, 32)
			elbow_start = 24.0
			wrist_start = Vector3(-145, -18, -32)
			wrist_follow = Vector3(-130, 12, -25)
			body_start = Vector3(0, -20, -3)
			body_follow = Vector3(0, 18, 3)
		SwordSwing.BACKHAND:
			windup = Vector3(88, 42, 20)
			start = Vector3(68, 25, 28)
			follow = Vector3(42, -48, 52)
			elbow_start = 28.0
			elbow_follow = 32.0
			wrist_start = Vector3(-150, 15, 24)
			wrist_follow = Vector3(-135, -20, 38)
			body_start = Vector3(0, 16, 2)
			body_follow = Vector3(0, -18, -3)
		SwordSwing.OVERHEAD:
			windup = Vector3(156, -8, 16)
			start = Vector3(105, -8, 18)
			follow = Vector3(25, -6, 20)
			elbow_start = 20.0
			elbow_follow = 14.0
			wrist_start = Vector3(-152, 0, -6)
			wrist_follow = Vector3(-120, 0, -6)
			body_start = Vector3(-5, -4, 0)
			body_follow = Vector3(8, 5, 0)
	var body_pose: Vector3
	if t < clock.windup_end:
		var p: float = clock.phase_progress(0, clock.windup_end)
		var prepare := smoothstep(0, 0.70, p)
		var strike := smoothstep(0.70, 1, p)
		_arm_r.rotation_degrees = _attack_entry_arm.lerp(windup, prepare).lerp(start, strike)
		_elbow_r.rotation_degrees.x = lerpf(lerpf(_attack_entry_elbow, 65, prepare), elbow_start, strike)
		_wrist_degrees = _attack_entry_wrist.lerp(Vector3(-170, 0, 0), prepare).lerp(wrist_start, strike)
		body_pose = Vector3.ZERO.lerp(body_start, prepare)
	elif t < contact_end:
		var k := smoothstep(clock.windup_end, contact_end, t)
		_arm_r.rotation_degrees = start.lerp(follow, k)
		_elbow_r.rotation_degrees.x = lerpf(elbow_start, elbow_follow, k)
		_wrist_degrees = wrist_start.lerp(wrist_follow, k)
		body_pose = body_start.lerp(body_follow, k)
	else:
		var k := smoothstep(contact_end, 1.0, t)
		_arm_r.rotation_degrees = follow.lerp(_arm_r.rotation_degrees, k)
		_elbow_r.rotation_degrees.x = lerpf(elbow_follow, _elbow_r.rotation_degrees.x, k)
		_wrist_degrees = wrist_follow.lerp(REST_SWORD, k)
		body_pose = body_follow.lerp(Vector3.ZERO, k)
	# Most rotation stays above the hips so planted feet don't sweep sideways.
	_pivot.rotation_degrees += body_pose * 0.2
	_torso.rotation_degrees += body_pose * 0.8
	_arm_r.rotation_degrees.y += body_pose.y * 0.8
	_arm_l.rotation_degrees.y += body_pose.y * 0.45
	_head.rotation_degrees.y -= body_pose.y * 0.3
	_slash_trail.visible = _g.combat_state == Gladiator.CombatState.ACTIVE_HIT


func _animate_kick() -> void:
	if _kick_t < 0.0:
		return
	var t := clampf(_kick_t / maxf(kick_anim_time, 0.01), 0, 1)
	var clock := _g.combat_animation
	var prepare := smoothstep(0, clock.windup_end, t)
	var release := smoothstep(clock.windup_end * 0.65, clock.windup_end, t)
	var strength := prepare * (1.0 - smoothstep(clock.active_end, 1.0, t))
	_leg_r.rotation_degrees.x = lerpf(rad_to_deg(_leg_r.rotation.x), lerpf(60, 83, release), strength)
	_knee_r.rotation_degrees.x = lerpf(rad_to_deg(_knee_r.rotation.x), lerpf(-105, -12, release), strength)
	_knee_r.get_node("Foot").rotation_degrees.x = -15 * strength
	_pivot.rotation.x = deg_to_rad(-9.0) * strength


func _animate_secondary_motion(delta: float) -> void:
	var breath := sin(_idle_phase) * 0.006 * secondary_motion
	_torso.scale = Vector3(1.0 + breath, 1.0 + breath * 0.3, 1.0 + breath)
	var flow := clampf(-_local_velocity.z / maxf(_g.move_speed, 0.001), -0.5, 1.0)
	var side := clampf(_local_velocity.x / maxf(_g.move_speed, 0.001), -1, 1)
	var wave := sin(_idle_phase * 2.0 + _walk_phase) * (1.2 + _move_amount * 3.0)
	var k := Motion.weight(delta, 8.0)
	_cape_root.rotation_degrees.z = lerpf(_cape_root.rotation_degrees.z, side * 5, k)
	_cape_a.rotation_degrees.x = lerpf(_cape_a.rotation_degrees.x, -5 - flow * 8 + wave * 0.3, k)
	_cape_b.rotation_degrees.x = lerpf(_cape_b.rotation_degrees.x, -flow * 9 + wave * 0.7, k)
	_cape_c.rotation_degrees.x = lerpf(_cape_c.rotation_degrees.x, -flow * 11 + wave, k)
	_cape_d.rotation_degrees.x = lerpf(_cape_d.rotation_degrees.x, -flow * 13 + wave * 1.3, k)
	if _hurt_t > 0.0:
		var recoil := sin(PI * clampf(_hurt_t / 0.32, 0, 1))
		var power := (15.0 if _hurt_heavy else 8.0) * recoil
		_torso.rotation_degrees.x += _hurt_direction.z * power
		_torso.rotation_degrees.z -= _hurt_direction.x * power
		_head.rotation_degrees.y -= _hurt_direction.x * power * 0.6


func _animate_stagger(delta: float) -> void:
	if _g.stun_time <= 0.0:
		_stagger_phase = 0.0
		_head.rotation.z = 0.0
		return

	_attack_t = -1.0
	_kick_t = -1.0
	_slash_trail.visible = false
	_stagger_phase += delta
	var shake := exp(-_stagger_phase * 7.0)
	_pivot.rotation.z = deg_to_rad(9.0) * sin(_stagger_phase * 22.0) * shake
	_head.rotation.z = deg_to_rad(-6.0) * sin(_stagger_phase * 15.0) * shake
	_arm_r.rotation_degrees = _recoil_arm.lerp(_arm_r.rotation_degrees, smoothstep(0, 0.20, _stagger_phase))
	# Щит выбит - рука падает
	_arm_l.rotation_degrees = REST_ARM_L
	_sync_shield()


func _animate_death(delta: float) -> void:
	if _death_t <= 0.0:
		_sfx.play(SND_DIE, 0.0)
		_death_arm_r = _arm_r.rotation_degrees
		_death_arm_l = _arm_l.rotation_degrees
		_death_rotation = _pivot.rotation_degrees
	_death_t = minf(_death_t + delta, 1.0)
	var k := smoothstep(0.0, 1.0, _death_t)

	_pivot.rotation_degrees = _death_rotation.lerp(Vector3(88.0, 0, -_hurt_direction.x * 12), k)
	_pivot.position.y = 0.16 * k
	_arm_r.rotation_degrees = _death_arm_r.lerp(Vector3(-40.0, 0.0, -25.0), k)
	_arm_l.rotation_degrees = _death_arm_l.lerp(Vector3(-30.0, 0.0, 25.0), k)
	_slash_trail.visible = false
	_blade.material_overlay = null
	_sync_equipment()
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
	_attack_entry_arm = _arm_r.rotation_degrees
	_attack_entry_elbow = _elbow_r.rotation_degrees.x
	_attack_entry_wrist = _wrist_degrees
	if attack_type == Gladiator.AttackType.SWORD:
		# Local sequence gives every fighter all four swings without consuming
		# the gameplay RNG or changing attacks, damage, cooldowns or RL state.
		_sword_swing = _next_sword_swing as SwordSwing
		_next_sword_swing = (_next_sword_swing + 1) % SwordSwing.size()
		_kick_t = -1.0
		_attack_t = 0.0

	else:
		_attack_t = -1.0
		_kick_t = 0.0


func _on_attack_contact(attack_type: int) -> void:
	_sfx.play(SND_SWING if attack_type == Gladiator.AttackType.SWORD else SND_KICK, -6.0)


func _on_hit_reaction(direction: Vector3, heavy: bool) -> void:
	_recoil_arm = _arm_r.rotation_degrees
	_hurt_direction = direction
	_hurt_heavy = heavy
	_hurt_t = 0.32


func _on_dealt_damage(_amount: float, _target: Node3D, _type: int) -> void:
	_sfx.play(SND_HIT, -2.0)


func _on_took_damage(_amount: float, blocked: bool) -> void:
	_flash = flash_time
	_flash_mat.albedo_color = block_flash_color if blocked else flash_color
	if not blocked:
		_sfx.play(SND_HURT, -3.0)


func _on_damage_blocked(_absorbed: float) -> void:
	_flash = flash_time
	_flash_mat.albedo_color = block_flash_color
	_sfx.play(SND_BLOCK, 1.0)


func _on_guard_broken() -> void:
	_on_hit_reaction(Vector3.BACK, true)
	_flash = flash_time
	_flash_mat.albedo_color = Color(1.0, 0.9, 0.3)
	_sfx.play(SND_GUARD_BREAK, 1.0)


## Подъём - это не респавн: поза сбрасывается, а счётчики боя нет.
func _on_revived(_hp: float) -> void:
	_on_respawned()


func _on_respawned() -> void:
	_death_t = 0.0
	_attack_t = -1.0
	_kick_t = -1.0
	_block_amt = 0.0
	_sword_swing = SwordSwing.DIAGONAL
	_next_sword_swing = 0
	_flash = 0.0
	_walk_phase = 0.0
	_idle_phase = 0.0
	_hurt_t = 0.0
	_hurt_direction = Vector3.ZERO
	_guard_basis = Basis.IDENTITY
	_guard_yaw = 0.0
	_guard_pitch = 0.0
	_lean = Vector3.ZERO
	_last_velocity = Vector3.ZERO
	_stagger_phase = 0.0
	_move_amount = 0.0
	_local_velocity = Vector3.ZERO
	_step_sign = 1.0
	_torso.scale = Vector3.ONE
	_set_overlay(null)
	_blade.material_overlay = null
	_apply_rest_pose()


# ------------------------------------------------------------------
# Вспомогательное
# ------------------------------------------------------------------

func _collect_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.is_visible_in_tree() and child.mesh != null:
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

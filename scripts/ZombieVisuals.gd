extends Node3D

const PV := preload("res://scripts/ProceduralVisuals.gd")
const Geometry := preload("res://scripts/CharacterGeometry.gd")
const Motion := preload("res://scripts/CharacterMotion.gd")

## Визуал зомби. Та же схема, что и у гладиатора: поза целиком выводится
## из состояния Zombie.gd, ни одной аллокации за кадр, ветка отключаема целиком.

@export_group("Походка")
@export var walk_cycle_speed: float = 3.4
@export var stride_length: float = 0.25
@export var shamble_deg: float = 5.0       ## заваливание корпуса вбок при шаге
@export var bob_height: float = 0.008

@export_group("Реакции")
@export var flash_color: Color = Color(1.0, 0.35, 0.3)
@export var flash_time: float = 0.18
@export var twitch_strength: float = 1.0

# Базовая поза: сутулый, руки вытянуты вперёд
const REST_TORSO := Vector3(-12.0, 0.0, 0.0)
const REST_ARM_R := Vector3(22.0, 0.0, -12.0)
const REST_ARM_L := Vector3(32.0, 0.0, 10.0)
const WINDUP_ARM := Vector3(108.0, -10.0, -17.0)
const STRIKE_ARM := Vector3(62.0, 14.0, -10.0)

@onready var _pivot: Node3D = $Body
@onready var _torso: Node3D = $Body/Torso
@onready var _head: Node3D = $Body/Torso/Head
@onready var _jaw: Node3D = $Body/Torso/Head/Jaw
@onready var _arm_r: Node3D = $Body/Torso/ArmR
@onready var _arm_l: Node3D = $Body/Torso/ArmL
@onready var _leg_l: Node3D = $Body/LegL
@onready var _leg_r: Node3D = $Body/LegR
@onready var _bar: Node3D = $HealthBar3D
@onready var _sfx: SfxPlayer = $Sfx

const SND_GROWL := preload("res://audio/zombie_growl.wav")
const SND_DIE := preload("res://audio/zombie_die.wav")

var _elbow_r: Node3D
var _elbow_l: Node3D
var _knee_r: Node3D
var _knee_l: Node3D
var _move_amount := 0.0
var _local_velocity := Vector3.ZERO
var _brute_growth: Node3D
var _z: Zombie

var _walk_phase: float = 0.0
var _flash: float = 0.0
var _death_t: float = 0.0
var _stagger_phase: float = 0.0
var _arm_blend: float = 0.0     ## 0 = покой, 1 = замах
var _growl_timer: float = 0.0
var _was_windup: bool = false
var _idle_phase: float = 0.0
var _attack_pulse: float = 0.0
var _hurt_t := 0.0
var _hurt_direction := Vector3.ZERO
var _hurt_heavy := false
var _entry_r := REST_ARM_R
var _entry_l := REST_ARM_L
var _entry_torso := REST_TORSO
var _telegraph_mat: StandardMaterial3D
var _last_overlay: Material
var _audio_rng := RandomNumberGenerator.new()
var _death_arm_r := REST_ARM_R
var _death_arm_l := REST_ARM_L
var _death_rotation := Vector3.ZERO

var _meshes: Array[MeshInstance3D] = []
var _flash_mat: StandardMaterial3D
var _variant_mat: StandardMaterial3D
var _eye_l: MeshInstance3D
var _eye_r: MeshInstance3D
var _rag_a: Node3D
var _rag_b: Node3D
var _eye_mat: StandardMaterial3D


func _ready() -> void:
	_audio_rng.randomize()
	_z = get_parent() as Zombie
	if _z == null:
		push_error("ZombieVisuals должен быть дочерней нодой Zombie")
		set_process(false)
		return

	Geometry.zombie(self)
	_elbow_r = _arm_r.get_node("Elbow")
	_elbow_l = _arm_l.get_node("Elbow")
	_knee_r = _leg_r.get_node("Knee")
	_knee_l = _leg_l.get_node("Knee")
	_create_signature_details()
	_collect_meshes($Body)
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_mat.albedo_color = Color(flash_color.r, flash_color.g, flash_color.b, 0.0)

	_z.damaged.connect(_on_damaged)
	_z.respawned.connect(_on_respawned)
	_z.hit_reaction.connect(_on_hit_reaction)
	_z.attack_started.connect(_on_attack_started)
	_variant_mat = StandardMaterial3D.new()
	_variant_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_variant_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_telegraph_mat = _variant_mat.duplicate()
	_telegraph_mat.albedo_color = Color(1.0, 0.53, 0.08, 0.12)

	_apply_rest_pose()


## Глаза, подвижные лоскуты и костяные наросты тяжёлой разновидности.
func _create_signature_details() -> void:
	_eye_mat = PV.material(Color(0.8, 0.28, 0.035), 0.0, 0.5,
		Color(0.9, 0.16, 0.015), 1.2)
	_eye_l = Geometry.ellipsoid(_head, "EyeL", Vector3(-0.062, 0.025, -0.105),
		Vector3(0.016, 0.011, 0.009), _eye_mat)
	_eye_r = Geometry.ellipsoid(_head, "EyeR", Vector3(0.062, 0.025, -0.105),
		Vector3(0.016, 0.011, 0.009), _eye_mat)
	_rag_a = _pivot.get_node("Rag2")
	_rag_b = _pivot.get_node("Rag7")
	_brute_growth = Geometry.joint(_torso, "BruteGrowth", Vector3.ZERO)
	var bone := Geometry.material("bone", Color("aba58a"))
	for side in [-1.0, 1.0]:
		for i in 3:
			Geometry.ellipsoid(_brute_growth, "BonePlate", Vector3(side * (0.22 + i * 0.026),
				0.25 - i * 0.06, 0.02), Vector3(0.08, 0.075, 0.12), bone)
	_brute_growth.hide()


func _process(delta: float) -> void:
	if _z == null:
		return

	_flash = maxf(0.0, _flash - delta)
	_hurt_t = maxf(0.0, _hurt_t - delta)

	if _z.state == Zombie.State.DEAD:
		if _death_t <= 0.0:
			_sfx.play(SND_DIE, -4.0, 0.18)
		_animate_death(delta)
		_apply_flash()
		return

	_update_growl(delta)

	# Видимостью полосы распоряжается она сама: у целого зомби её не видно
	_bar.set_ratio(_z.health / maxf(_z.max_health, 0.001))

	_animate_locomotion(delta)
	_animate_arms(delta)
	_animate_stagger(delta)
	_animate_secondary_motion(delta)
	_apply_flash()


# ------------------------------------------------------------------
# Поза
# ------------------------------------------------------------------

## Рычание с разной задержкой у каждого зомби: синхронный хор из восьми
## одинаковых рыков звучит как один громкий баг.
func _update_growl(delta: float) -> void:
	_growl_timer -= delta
	_idle_phase += delta * (1.6 + Vector2(_z.velocity.x, _z.velocity.z).length() * 0.22)
	_attack_pulse = maxf(0.0, _attack_pulse - delta * 4.0)

	# Замах озвучиваем всегда - это сигнал игроку и агенту, что сейчас ударят
	var windup := _z.state == Zombie.State.WINDUP
	if windup and not _was_windup:
		_sfx.play(SND_GROWL, -6.0, 0.25)
		_growl_timer = _audio_rng.randf_range(3.0, 6.0)
	_was_windup = windup

	if _growl_timer <= 0.0:
		_sfx.play(SND_GROWL, -14.0, 0.25)
		_growl_timer = _audio_rng.randf_range(3.0, 7.0)


func _apply_rest_pose() -> void:
	_pivot.rotation = Vector3.ZERO
	_pivot.position = Vector3.ZERO
	_torso.rotation_degrees = REST_TORSO
	_arm_r.rotation_degrees = REST_ARM_R
	_arm_l.rotation_degrees = REST_ARM_L
	_leg_l.rotation = Vector3.ZERO
	_leg_r.rotation = Vector3.ZERO
	_knee_l.rotation = Vector3.ZERO
	_knee_r.rotation = Vector3.ZERO
	_knee_l.get_node("Foot").rotation = Vector3.ZERO
	_knee_r.get_node("Foot").rotation = Vector3.ZERO
	_elbow_r.rotation_degrees = Vector3(18, 0, 0)
	_elbow_l.rotation_degrees = Vector3(27, 0, 0)
	_head.rotation = Vector3.ZERO
	_jaw.rotation = Vector3.ZERO
	_jaw.scale = Vector3.ONE
	if _rag_a != null:
		_rag_a.rotation.x = 0.0
		_rag_a.rotation.z = 0.0
		_rag_b.rotation.x = 0.0
		_rag_b.rotation.z = 0.0


func _animate_locomotion(delta: float) -> void:
	var local := _z.global_basis.orthonormalized().inverse() * _z.velocity
	local.y = 0
	# Knockback is a slide, not a running animation.
	if _z.state == Zombie.State.STAGGER:
		local = Vector3.ZERO
	_local_velocity = _local_velocity.lerp(local, Motion.weight(delta))
	var speed := _local_velocity.length()
	_move_amount = lerpf(_move_amount, clampf(speed / maxf(_z.move_speed, 0.1), 0, 1), Motion.weight(delta))
	if speed > 0.05:
		var cadence := 1.12 if _z.variant == Zombie.Variant.RUNNER else (0.8 if _z.variant == Zombie.Variant.BRUTE else 1.0)
		_walk_phase = fmod(_walk_phase + delta * speed * walk_cycle_speed * cadence, TAU)
	var direction := _local_velocity.normalized() if speed > 0.05 else Vector3.FORWARD
	_pivot.position.y = sin(_walk_phase * 2.0) * bob_height * _move_amount
	var sway := 0.25 if _z.variant == Zombie.Variant.RUNNER else (0.65 if _z.variant == Zombie.Variant.BRUTE else 0.45)
	_pivot.rotation = Vector3(0, 0, deg_to_rad(shamble_deg) * sin(_walk_phase) * _move_amount * sway)
	Motion.leg(_leg_l, _knee_l, _walk_phase, _move_amount, direction, 0.38, 0.34, _pivot.position.y, 1.0, stride_length)
	Motion.leg(_leg_r, _knee_r, _walk_phase + PI, _move_amount, direction, 0.38, 0.34, _pivot.position.y,
		1.0 if _z.variant == Zombie.Variant.RUNNER else 0.55, stride_length)
	_head.rotation_degrees.y = sin(_walk_phase) * 3.0 * _move_amount


func _animate_arms(delta: float) -> void:
	var gait := sin(_walk_phase) * _move_amount
	var run := _z.variant == Zombie.Variant.RUNNER
	var brute := _z.variant == Zombie.Variant.BRUTE
	var target_r := REST_ARM_R + Vector3(gait * (24 if run else 8), 0, 0)
	var target_l := REST_ARM_L - Vector3(gait * (24 if run else 6), 0, 0)
	var elbow := 18.0
	var torso := REST_TORSO.x - (8.0 if run else 0.0) * _move_amount
	var twist := gait * (5.0 if run else 2.5)
	var head := 0.0
	var jaw := 3.0
	_arm_blend = 0.0
	var side: float = _z.attack_side
	var wind_r := Vector3(112, -22, -24)
	var wind_l := Vector3(46, 12, 18)
	var contact_r := Vector3(68, 24, -12)
	var contact_l := Vector3(38, -10, 10)
	var follow_r := Vector3(28, 38, -8)
	var follow_l := Vector3(28, -8, 10)
	if run:
		wind_r = Vector3(80, -48, -30)
		contact_r = Vector3(75, 28, -15)
		follow_r = Vector3(40, 48, -10)
	elif brute:
		wind_r = Vector3(142, -12, -20)
		wind_l = Vector3(142, 12, 20)
		contact_r = Vector3(70, 6, -14)
		contact_l = Vector3(70, -6, 14)
		follow_r = Vector3(24, 6, -14)
		follow_l = Vector3(24, -6, 14)
	if side < 0 and not brute:
		var mirror := Vector3(1, -1, -1)
		var temp := wind_r
		wind_r = wind_l * mirror
		wind_l = temp * mirror
		temp = contact_r
		contact_r = contact_l * mirror
		contact_l = temp * mirror
		temp = follow_r
		follow_r = follow_l * mirror
		follow_l = temp * mirror
	var clock := _z.combat_animation
	match _z.state:
		Zombie.State.WINDUP:
			var progress: float = clock.phase_progress(0, clock.windup_end)
			var prepare := smoothstep(0.0, 0.72, progress)
			var strike := smoothstep(0.72, 1.0, progress)
			target_r = _entry_r.lerp(wind_r, prepare).lerp(contact_r, strike)
			target_l = _entry_l.lerp(wind_l, prepare).lerp(contact_l, strike)
			elbow = lerpf(lerpf(18, 58, prepare), 20, strike)
			torso = lerpf(_entry_torso.x, -3, prepare) - strike * 21
			twist = lerpf(-12, 8, strike) * prepare * side * (0.2 if brute else 1.0)
			head = -12 * prepare + strike * 20
			jaw = 3 + prepare * 19 - strike * 8
			_arm_blend = prepare
		Zombie.State.ACTIVE_HIT:
			var sweep := smoothstep(0, 1, clock.phase_progress(clock.windup_end, clock.active_end))
			target_r = contact_r.lerp(follow_r, sweep)
			target_l = contact_l.lerp(follow_l, sweep)
			elbow = lerpf(20, 14, sweep)
			torso = lerpf(-24, -30 if brute else -26, sweep)
			twist = lerpf(8, 16, sweep) * side * (0.2 if brute else 1.0)
			head = 8
			jaw = 14
			_arm_blend = 1.0
		Zombie.State.RECOVER:
			var recovery := smoothstep(0, 1, clock.phase_progress(clock.active_end, 1))
			target_r = follow_r.lerp(target_r, recovery)
			target_l = follow_l.lerp(target_l, recovery)
			elbow = lerpf(14, 18, recovery)
			torso = lerpf(-30 if brute else -26, torso, recovery)
			twist = lerpf(16 * side * (0.2 if brute else 1.0), twist, recovery)
			head = lerpf(8, 0, recovery)
			jaw = lerpf(14, 3, recovery)
			_arm_blend = 1.0 - recovery
	var roll := 0.0
	if _hurt_t > 0.0:
		var recoil := sin(PI * clampf(_hurt_t / 0.36, 0, 1))
		var strength := (23.0 if _hurt_heavy else 12.0) * recoil
		torso += _hurt_direction.z * strength
		roll = -_hurt_direction.x * strength
	# Attack curves are already eased. Extra smoothing here would delay contact
	# beyond the damage event and change that delay with rendering frame rate.
	var blend := 1.0 if clock.running else Motion.weight(delta, 16.0)
	_arm_r.rotation_degrees = _arm_r.rotation_degrees.lerp(target_r, blend)
	_arm_l.rotation_degrees = _arm_l.rotation_degrees.lerp(target_l, blend)
	_elbow_r.rotation_degrees.x = lerpf(_elbow_r.rotation_degrees.x, elbow, blend)
	_elbow_l.rotation_degrees.x = lerpf(_elbow_l.rotation_degrees.x, elbow + 9 * (1 - _arm_blend), blend)
	_head.rotation_degrees.x = lerpf(_head.rotation_degrees.x, head, blend)
	_torso.rotation_degrees.x = lerpf(_torso.rotation_degrees.x, torso, blend)
	_torso.rotation_degrees.y = lerpf(_torso.rotation_degrees.y, twist, blend)
	_torso.rotation_degrees.z = lerpf(_torso.rotation_degrees.z, roll, Motion.weight(delta, 22))
	_jaw.rotation_degrees.x = -jaw
	_attack_pulse = _arm_blend


func _animate_stagger(delta: float) -> void:
	if _z.state != Zombie.State.STAGGER:
		_stagger_phase = 0.0
		return
	_stagger_phase += delta
	var shake := exp(-_stagger_phase * 7.0)
	_pivot.rotation.z += deg_to_rad(8.0) * sin(_stagger_phase * 24) * shake
	_torso.rotation_degrees.x = lerpf(_torso.rotation_degrees.x, 8.0, Motion.weight(delta))
	_head.rotation_degrees.y = sin(_stagger_phase * 17.0) * 7.0 * shake


func _animate_secondary_motion(delta: float) -> void:
	_head.rotation_degrees.z = sin(_idle_phase * 2.7) * 1.5 * twitch_strength
	var wave := sin(_walk_phase + _idle_phase * 0.4) * (1.0 + _move_amount * 5.0)
	_rag_a.rotation_degrees.x = lerpf(_rag_a.rotation_degrees.x, wave, Motion.weight(delta, 8))
	_rag_b.rotation_degrees.x = lerpf(_rag_b.rotation_degrees.x, -wave * 0.8, Motion.weight(delta, 8))
	_eye_mat.emission_energy_multiplier = 1.2 + _attack_pulse * 0.6


func _animate_death(delta: float) -> void:
	if _death_t <= 0.0:
		_death_arm_r = _arm_r.rotation_degrees
		_death_arm_l = _arm_l.rotation_degrees
		_death_rotation = _pivot.rotation_degrees
	_bar.visible = false
	_death_t = minf(_death_t + delta, 1.3)
	var k := smoothstep(0.08, 0.85, _death_t)

	_pivot.rotation_degrees = _death_rotation.lerp(Vector3(-82, 0, -_hurt_direction.x * 18.0 + 5.0), k)
	_pivot.position.y = 0.18 * k - smoothstep(1.0, 1.3, _death_t) * 0.4
	_knee_r.rotation_degrees.x = -35 * sin(PI * k)
	_knee_l.rotation_degrees.x = -45 * sin(PI * k)
	_arm_r.rotation_degrees = _death_arm_r.lerp(Vector3(8.0, 0.0, -30.0), k)
	_arm_l.rotation_degrees = _death_arm_l.lerp(Vector3(8.0, 0.0, 30.0), k)
	if _death_t >= 1.3 and _z.retiring:
		_z.deactivate()


func _apply_flash() -> void:
	if _flash <= 0.0 and _z.state == Zombie.State.WINDUP:
		var p: float = _z.combat_animation.phase_progress(0, _z.combat_animation.windup_end)
		_telegraph_mat.albedo_color.a = 0.04 + smoothstep(0, 1, p) * 0.14
		_set_overlay(_telegraph_mat)
		return
	var a := _flash / maxf(flash_time, 0.001)
	if a <= 0.0:
		_flash_mat.albedo_color.a = 0.0
		var overlay: Material = _variant_mat if _variant_mat.albedo_color.a > 0.0 else null
		_set_overlay(overlay)
		return

	_flash_mat.albedo_color.a = a * 0.42
	_set_overlay(_flash_mat)


func _set_overlay(material: Material) -> void:
	if _last_overlay == material:
		return
	_last_overlay = material
	for m in _meshes:
		m.material_overlay = material


# ------------------------------------------------------------------
# Сигналы
# ------------------------------------------------------------------

func _on_damaged(_amount: float) -> void:
	_flash = flash_time


func _on_attack_started() -> void:
	_entry_r = _arm_r.rotation_degrees
	_entry_l = _arm_l.rotation_degrees
	_entry_torso = _torso.rotation_degrees


func _on_hit_reaction(direction: Vector3, heavy: bool) -> void:
	_hurt_t = 0.36
	_hurt_direction = direction
	_hurt_heavy = heavy


## Разновидность читается из тела при каждом появлении: пул переиспользует
## один и тот же узел под разные типы зомби.
func _apply_variant() -> void:
	_brute_growth.visible = _z.variant == Zombie.Variant.BRUTE
	match _z.variant:
		Zombie.Variant.RUNNER:
			scale = Vector3(0.82, 0.9, 0.82)
			_variant_mat.albedo_color = Color(0.55, 0.48, 0.25, 0.09)
			_eye_mat.albedo_color = Color(1.0, 0.8, 0.06)
			_eye_mat.emission = Color(1.0, 0.35, 0.01)
		Zombie.Variant.BRUTE:
			scale = Vector3(1.32, 1.28, 1.32)
			_variant_mat.albedo_color = Color(0.32, 0.26, 0.36, 0.10)
			_eye_mat.albedo_color = Color(0.72, 0.12, 1.0)
			_eye_mat.emission = Color(0.38, 0.02, 0.9)
		_:
			scale = Vector3.ONE
			_variant_mat.albedo_color = Color(0, 0, 0, 0)
			_eye_mat.albedo_color = Color(1.0, 0.06, 0.015)
			_eye_mat.emission = Color(1.0, 0.015, 0.005)

	var overlay: Material = _variant_mat if _variant_mat.albedo_color.a > 0.0 else null
	_set_overlay(overlay)


func _on_respawned() -> void:
	_death_t = 0.0
	_hurt_t = 0.0
	_hurt_direction = Vector3.ZERO
	_growl_timer = _audio_rng.randf_range(0.5, 4.0)
	_was_windup = false
	_flash = 0.0
	_walk_phase = fmod(float(get_index()) * 2.399963, TAU)
	_move_amount = 0.0
	_local_velocity = Vector3.ZERO
	_stagger_phase = 0.0
	_arm_blend = 0.0
	_idle_phase = fmod(float(get_index()) * 1.7, TAU)
	_eye_mat.emission_energy_multiplier = 1.2
	_attack_pulse = 0.0
	_apply_rest_pose()
	_bar.visible = true
	# Окраску разновидности ставим ПОСЛЕ сброса, иначе она бы тут же стёрлась
	_apply_variant()


func _collect_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.visible and child.mesh != null:
			_meshes.append(child)
		_collect_meshes(child)

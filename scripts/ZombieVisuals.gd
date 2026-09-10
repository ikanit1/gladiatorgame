extends Node3D

const PV := preload("res://scripts/ProceduralVisuals.gd")

## Визуал зомби. Та же схема, что и у гладиатора: поза целиком выводится
## из состояния Zombie.gd, ни одной аллокации за кадр, ветка отключаема целиком.

@export_group("Походка")
@export var walk_cycle_speed: float = 3.4
@export var leg_swing_deg: float = 30.0
@export var shamble_deg: float = 5.0       ## заваливание корпуса вбок при шаге
@export var bob_height: float = 0.03

@export_group("Реакции")
@export var flash_color: Color = Color(1.0, 0.35, 0.3)
@export var flash_time: float = 0.18
@export var twitch_strength: float = 1.0

# Базовая поза: сутулый, руки вытянуты вперёд
const REST_TORSO := Vector3(14.0, 0.0, 0.0)
const REST_ARM_R := Vector3(-62.0, 0.0, -9.0)
const REST_ARM_L := Vector3(-62.0, 0.0, 9.0)
const WINDUP_ARM := Vector3(-118.0, 0.0, 0.0)
const STRIKE_ARM := Vector3(-22.0, 0.0, 0.0)

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

var _meshes: Array[MeshInstance3D] = []
var _flash_mat: StandardMaterial3D
var _variant_mat: StandardMaterial3D
var _eye_l: MeshInstance3D
var _eye_r: MeshInstance3D
var _rag_a: Node3D
var _rag_b: Node3D
var _eye_mat: StandardMaterial3D


func _ready() -> void:
	_z = get_parent() as Zombie
	if _z == null:
		push_error("ZombieVisuals должен быть дочерней нодой Zombie")
		set_process(false)
		return

	_create_signature_details()
	_collect_meshes($Body)
	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_mat.albedo_color = Color(flash_color.r, flash_color.g, flash_color.b, 0.0)

	_z.damaged.connect(_on_damaged)
	_z.respawned.connect(_on_respawned)
	_variant_mat = StandardMaterial3D.new()
	_variant_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_variant_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	_apply_rest_pose()


## Дополнительные детали превращают силуэт из набора кубов в узнаваемого
## мутировавшего бойца: глаза, рёбра, позвоночник, свисающие лоскуты и слизь.
## Всё создаётся один раз, поэтому пул из зомби не получает лишних аллокаций.
func _create_signature_details() -> void:
	_eye_mat = PV.material(Color(1.0, 0.06, 0.015), 0.0, 0.2,
		Color(1.0, 0.015, 0.005), 6.0)
	var bone := PV.material(Color(0.56, 0.65, 0.43), 0.0, 0.78)
	var dark_bone := PV.material(Color(0.12, 0.16, 0.10), 0.0, 0.9)
	var rag := PV.material(Color(0.15, 0.055, 0.045), 0.0, 0.95)
	var slime := PV.material(Color(0.22, 0.55, 0.16), 0.0, 0.35,
		Color(0.12, 0.65, 0.05), 1.4)

	_eye_l = PV.sphere(_head, "EyeL", 0.034,
		Vector3(-0.075, 0.025, -0.135), _eye_mat, 0.055)
	_eye_r = PV.sphere(_head, "EyeR", 0.034,
		Vector3(0.075, 0.025, -0.135), _eye_mat, 0.055)

	for i in 3:
		var rib_y := 0.02 + float(i) * 0.105
		PV.box(_torso, "RibL%d" % i,
			Vector3(0.16, 0.035, 0.035), Vector3(-0.12, rib_y, -0.18), bone)
		PV.box(_torso, "RibR%d" % i,
			Vector3(0.16, 0.035, 0.035), Vector3(0.12, rib_y, -0.18), bone)
		PV.sphere(_torso, "Spine%d" % i, 0.04,
			Vector3(0.0, rib_y + 0.03, 0.18), dark_bone, 0.075)

	var rag_root := Node3D.new()
	rag_root.name = "HangingRags"
	rag_root.position = Vector3(0.0, 0.86, 0.14)
	_pivot.add_child(rag_root)
	_rag_a = _rag_segment(rag_root, "RagA", Vector3(-0.22, -0.28, 0.0),
		Vector3(0.22, 0.52, 0.045), rag)
	_rag_b = _rag_segment(rag_root, "RagB", Vector3(0.18, -0.34, 0.025),
		Vector3(0.18, 0.62, 0.04), rag)
	PV.sphere(rag_root, "Slime", 0.052,
		Vector3(-0.04, -0.56, -0.01), slime, 0.10)


func _rag_segment(parent: Node3D, segment_name: String, pos: Vector3,
		size: Vector3, material: Material) -> Node3D:
	var segment := Node3D.new()
	segment.name = segment_name
	segment.position = pos
	parent.add_child(segment)
	PV.box(segment, "Cloth", size, Vector3.ZERO, material)
	return segment


func _process(delta: float) -> void:
	if _z == null:
		return

	_flash = maxf(0.0, _flash - delta)

	if _z.state == Zombie.State.DEAD:
		if _death_t <= 0.0:
			_sfx.play(SND_DIE, -4.0, 0.18)
		_animate_death(delta)
		_apply_flash()
		return

	_update_growl(delta)

	_bar.visible = true
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
		_growl_timer = randf_range(3.0, 6.0)
	_was_windup = windup

	if _growl_timer <= 0.0:
		_sfx.play(SND_GROWL, -14.0, 0.25)
		_growl_timer = randf_range(3.0, 7.0)


func _apply_rest_pose() -> void:
	_pivot.rotation = Vector3.ZERO
	_pivot.position = Vector3.ZERO
	_torso.rotation_degrees = REST_TORSO
	_arm_r.rotation_degrees = REST_ARM_R
	_arm_l.rotation_degrees = REST_ARM_L
	_leg_l.rotation = Vector3.ZERO
	_leg_r.rotation = Vector3.ZERO
	_head.rotation = Vector3.ZERO
	_jaw.rotation = Vector3.ZERO
	_jaw.scale = Vector3.ONE
	if _rag_a != null:
		_rag_a.rotation = Vector3.ZERO
		_rag_b.rotation = Vector3.ZERO


func _animate_locomotion(delta: float) -> void:
	var speed := Vector2(_z.velocity.x, _z.velocity.z).length()
	if speed > 0.1:
		_walk_phase += delta * speed * walk_cycle_speed

	var amp := clampf(speed / maxf(_z.move_speed, 0.001), 0.0, 1.0)
	var swing := sin(_walk_phase) * deg_to_rad(leg_swing_deg) * amp

	_leg_l.rotation.x = swing
	_leg_r.rotation.x = -swing
	_pivot.position.y = absf(sin(_walk_phase)) * bob_height * amp
	# Заваливание вбок - делает походку "неживой"
	_pivot.rotation.z = deg_to_rad(shamble_deg) * sin(_walk_phase) * amp
	_arm_r.rotation_degrees.z = REST_ARM_R.z + sin(_walk_phase * 0.9) * 8.0 * amp
	_arm_l.rotation_degrees.z = REST_ARM_L.z - sin(_walk_phase * 0.9) * 8.0 * amp
	_head.rotation_degrees.y = sin(_walk_phase * 0.45) * 5.0 * amp


func _animate_arms(delta: float) -> void:
	var want: float = 0.0
	var target_r := REST_ARM_R
	var target_l := REST_ARM_L
	var head_deg := 0.0
	var jaw_open := 0.0

	match _z.state:
		Zombie.State.WINDUP:
			want = 1.0
			target_r = WINDUP_ARM
			target_l = WINDUP_ARM
			head_deg = -18.0     # запрокидывает голову перед укусом
			jaw_open = 28.0
		Zombie.State.RECOVER:
			want = 1.0
			target_r = STRIKE_ARM
			target_l = STRIKE_ARM
			head_deg = 12.0
			jaw_open = 14.0

	# Замах поднимается плавно, удар должен быть резким
	var rate := 9.0 if _z.state == Zombie.State.WINDUP else 26.0
	_arm_blend = move_toward(_arm_blend, want, delta * rate)

	_arm_r.rotation_degrees = REST_ARM_R.lerp(target_r, _arm_blend)
	_arm_l.rotation_degrees = REST_ARM_L.lerp(target_l, _arm_blend)
	_head.rotation_degrees.x = lerpf(0.0, head_deg, _arm_blend)
	_torso.rotation_degrees.x = REST_TORSO.x + lerpf(0.0, -10.0, _arm_blend)
	_jaw.rotation_degrees.x = jaw_open * _arm_blend
	_jaw.scale = Vector3.ONE * (1.0 + _arm_blend * 0.08)
	_attack_pulse = maxf(_attack_pulse, _arm_blend)


func _animate_stagger(delta: float) -> void:
	if _z.state != Zombie.State.STAGGER:
		_stagger_phase = 0.0
		return

	_stagger_phase += delta * 18.0
	_pivot.rotation.z += deg_to_rad(11.0) * sin(_stagger_phase)
	_torso.rotation_degrees.x = REST_TORSO.x - 22.0   # отброшен назад
	_head.rotation_degrees.y = sin(_stagger_phase * 0.7) * 12.0


func _animate_secondary_motion(_delta: float) -> void:
	# Голова и глаза слегка живут сами по себе, а лоскуты реагируют на скорость.
	var twitch := sin(_idle_phase * 2.7) * 2.5 * twitch_strength
	_head.rotation_degrees.z = twitch
	var speed := Vector2(_z.velocity.x, _z.velocity.z).length()
	var wind := clampf(speed / maxf(_z.move_speed, 0.001), 0.0, 1.0)
	var rag_wave := sin(_walk_phase * 0.75 + _idle_phase * 0.4) * (0.08 + wind * 0.16)
	if _rag_a != null:
		_rag_a.rotation_degrees.x = rag_wave
		_rag_a.rotation_degrees.z = -rag_wave * 0.6
		_rag_b.rotation_degrees.x = rag_wave * 1.35
		_rag_b.rotation_degrees.z = rag_wave * 0.8
	if _z.state != Zombie.State.WINDUP and _z.state != Zombie.State.RECOVER:
		_arm_r.rotation_degrees.z += sin(_walk_phase * 0.9) * 7.0 * wind
		_arm_l.rotation_degrees.z -= sin(_walk_phase * 0.9) * 7.0 * wind
	if _eye_l != null:
		var eye_scale := 1.0 + sin(_idle_phase * 3.1) * 0.12 + _attack_pulse * 0.22
		_eye_l.scale = Vector3.ONE * eye_scale
		_eye_r.scale = Vector3.ONE * eye_scale


func _animate_death(delta: float) -> void:
	_bar.visible = false
	_death_t = minf(_death_t + delta, 1.0)
	var k := 1.0 - pow(1.0 - _death_t, 3.0)

	_pivot.rotation.x = deg_to_rad(-82.0) * k
	_pivot.rotation.z = deg_to_rad(14.0) * k
	_pivot.position.y = -0.35 * k
	_arm_r.rotation_degrees = REST_ARM_R.lerp(Vector3(-8.0, 0.0, -30.0), k)
	_arm_l.rotation_degrees = REST_ARM_L.lerp(Vector3(-8.0, 0.0, 30.0), k)


func _apply_flash() -> void:
	var a := _flash / maxf(flash_time, 0.001)
	if a <= 0.0:
		if _flash_mat.albedo_color.a > 0.0:
			_flash_mat.albedo_color.a = 0.0
			_apply_variant()   # возвращаем окраску разновидности
		return

	_flash_mat.albedo_color.a = a * 0.42
	for m in _meshes:
		m.material_overlay = _flash_mat


# ------------------------------------------------------------------
# Сигналы
# ------------------------------------------------------------------

func _on_damaged(_amount: float) -> void:
	_flash = flash_time


## Разновидность читается из тела при каждом появлении: пул переиспользует
## один и тот же узел под разные типы зомби.
func _apply_variant() -> void:
	match _z.variant:
		Zombie.Variant.RUNNER:
			scale = Vector3(0.82, 0.9, 0.82)
			_variant_mat.albedo_color = Color(0.95, 0.85, 0.25, 0.28)
			_eye_mat.albedo_color = Color(1.0, 0.8, 0.06)
			_eye_mat.emission = Color(1.0, 0.35, 0.01)
		Zombie.Variant.BRUTE:
			scale = Vector3(1.32, 1.28, 1.32)
			_variant_mat.albedo_color = Color(0.55, 0.2, 0.75, 0.3)
			_eye_mat.albedo_color = Color(0.72, 0.12, 1.0)
			_eye_mat.emission = Color(0.38, 0.02, 0.9)
		_:
			scale = Vector3.ONE
			_variant_mat.albedo_color = Color(0, 0, 0, 0)
			_eye_mat.albedo_color = Color(1.0, 0.06, 0.015)
			_eye_mat.emission = Color(1.0, 0.015, 0.005)

	var overlay: Material = _variant_mat if _variant_mat.albedo_color.a > 0.0 else null
	for m in _meshes:
		m.material_overlay = overlay


func _on_respawned() -> void:
	_death_t = 0.0
	_growl_timer = randf_range(0.5, 4.0)
	_was_windup = false
	_flash = 0.0
	_walk_phase = 0.0
	_stagger_phase = 0.0
	_arm_blend = 0.0
	_idle_phase = 0.0
	_attack_pulse = 0.0
	_apply_rest_pose()
	_bar.visible = true
	# Окраску разновидности ставим ПОСЛЕ сброса, иначе она бы тут же стёрлась
	_apply_variant()


func _collect_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_meshes.append(child)
		_collect_meshes(child)

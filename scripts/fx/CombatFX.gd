class_name CombatFX
extends Node3D

## Визуальный отклик боя: частицы попаданий, искры блока, пыль, числа урона.
##
## Отдельная ветка арены: скрытие старого Decor в подземелье не гасит бой.
## При visuals_enabled=false пулы и подписки вообще не создаются.
##
## Всё сделано пулами: эффект в бою срабатывает по несколько раз в секунду,
## а instantiate/queue_free на каждый удар - это мусор для сборщика ровно там,
## где нужен ровный кадр.

@export var pool_per_effect: int = 8
@export var number_pool: int = 12
@export var show_damage_numbers: bool = true
## Экранный масштаб всплывающих чисел. Работает вместе с fixed_size:
## размер задан в долях экрана, а не в метрах мира.
@export var number_pixel_size: float = 0.0009

enum Kind { HIT, BLOCK, DUST, DEATH, HEAL, STUN }

const BLOOD_TEXTURE := preload("res://assets/fx/blood_impact.png")
const BURST_LIFETIME := 0.32

var _pools: Dictionary = {}     # Kind -> Array[GPUParticles3D]
var _next: Dictionary = {}      # Kind -> int
var _numbers: Array[Label3D] = []
var _number_state: Array[Dictionary] = []
var _next_number: int = 0
var _bursts: Array[Sprite3D] = []
var _burst_times: Array[float] = []
var _next_burst := 0
var _zombies: Array[Zombie] = []
var _stuns: Array[Node3D] = []
var _stun_active: Array[bool] = []
var _stun_phase := 0.0
var _star_mesh: ArrayMesh
var _stun_material: StandardMaterial3D

var _arena: Arena


func _ready() -> void:
	# Пулы строим ТОЛЬКО убедившись, что визуал включён. Иначе при обучении
	# на 16 аренах появилось бы больше шестисот узлов частиц, которые никто
	# никогда не увидит, плюс живые подписки на каждый удар.
	set_process(false)
	_bind.call_deferred()


# ------------------------------------------------------------------
# Пулы
# ------------------------------------------------------------------

func _build_pools() -> void:
	var specs := {
		Kind.HIT: {"color": Color(0.55, 0.025, 0.018), "count": 16, "speed": 2.8,
			"life": 0.42, "size": 0.05, "gravity": -8.0, "spread": 75.0},
		Kind.BLOCK: {"color": Color(1.0, 0.86, 0.45), "count": 12, "speed": 6.5,
			"life": 0.35, "size": 0.06, "gravity": -6.0, "spread": 40.0},
		Kind.DUST: {"color": Color(0.78, 0.70, 0.55), "count": 7, "speed": 1.4,
			"life": 0.55, "size": 0.13, "gravity": -1.2, "spread": 80.0},
		Kind.DEATH: {"color": Color(0.42, 0.55, 0.32), "count": 22, "speed": 3.4,
			"life": 0.85, "size": 0.14, "gravity": -5.0, "spread": 90.0},
		Kind.HEAL: {"color": Color(0.4, 1.0, 0.55), "count": 14, "speed": 2.2,
			"life": 0.7, "size": 0.08, "gravity": 2.2, "spread": 35.0},
		Kind.STUN: {"color": Color(1.0, 0.65, 0.13), "count": 12, "speed": 1.6,
			"life": 0.4, "size": 0.07, "gravity": -0.8, "spread": 100.0},
	}

	for kind in specs:
		var arr: Array[GPUParticles3D] = []
		for i in pool_per_effect:
			var p := _make_particles(specs[kind], kind)
			add_child(p)
			arr.append(p)
		_pools[kind] = arr
		_next[kind] = 0
	_build_bursts()


func _make_particles(spec: Dictionary, kind: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0        # весь залп в один кадр, а не струйка
	p.amount = int(spec["count"])
	p.lifetime = float(spec["life"])
	p.local_coords = false       # частицы остаются на месте удара, а не едут за бойцом
	p.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = float(spec["spread"])
	mat.initial_velocity_min = float(spec["speed"]) * 0.45
	mat.initial_velocity_max = float(spec["speed"])
	mat.gravity = Vector3(0, float(spec["gravity"]), 0)
	mat.scale_min = 0.6
	mat.scale_max = 1.0
	mat.damping_min = 1.0
	mat.damping_max = 3.0
	# Гаснут к концу жизни, иначе исчезают резким щелчком
	var ramp := Gradient.new()
	ramp.set_color(0, spec["color"])
	ramp.set_color(1, Color(spec["color"].r, spec["color"].g, spec["color"].b, 0.0))
	var tex := GradientTexture1D.new()
	tex.gradient = ramp
	mat.color_ramp = tex
	p.process_material = mat

	var mesh: Mesh
	if kind == Kind.HIT:
		var droplet := SphereMesh.new()
		droplet.radius = float(spec["size"]) * 0.35
		droplet.height = float(spec["size"]) * 1.4
		droplet.radial_segments = 6
		droplet.rings = 3
		mesh = droplet
	else:
		var quad := QuadMesh.new()
		quad.size = Vector2(float(spec["size"]), float(spec["size"]))
		mesh = quad
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.vertex_color_use_as_albedo = true
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	if kind != Kind.HIT:
		# Soft discs instead of solid square particles for sparks/dust/healing.
		var gradient := Gradient.new()
		gradient.set_color(0, Color.WHITE)
		gradient.set_color(1, Color(1, 1, 1, 0))
		var texture := GradientTexture2D.new()
		texture.gradient = gradient
		texture.width = 32
		texture.height = 32
		texture.fill = GradientTexture2D.FILL_RADIAL
		texture.fill_from = Vector2(0.5, 0.5)
		texture.fill_to = Vector2(0.5, 0)
		qm.albedo_texture = texture
	mesh.material = qm
	p.draw_pass_1 = mesh
	return p


func _build_bursts() -> void:
	for i in pool_per_effect:
		var burst := Sprite3D.new()
		burst.name = "BloodImpact%d" % i
		burst.texture = BLOOD_TEXTURE
		burst.pixel_size = 0.001
		burst.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		burst.shaded = false
		burst.double_sided = true
		burst.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
		burst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		burst.visible = false
		add_child(burst)
		_bursts.append(burst)
		_burst_times.append(-1.0)


func _make_stun_indicator() -> Node3D:
	if _stun_material == null:
		_stun_material = StandardMaterial3D.new()
		_stun_material.albedo_color = Color(1.0, 0.66, 0.1)
		_stun_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_stun_material.emission_enabled = true
		_stun_material.emission = Color(1.0, 0.48, 0.035)
		_stun_material.emission_energy_multiplier = 1.8
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for tip in 10:
			st.add_vertex(Vector3.ZERO)
			for corner in [tip + 1, tip]:
				var angle := float(corner) * TAU / 10.0 + PI * 0.5
				var radius := 0.065 if corner % 2 == 0 else 0.028
				st.add_vertex(Vector3(cos(angle) * radius, sin(angle) * radius, 0))
		st.generate_normals()
		_star_mesh = st.commit()
	var indicator := Node3D.new()
	indicator.name = "StunIndicator%d" % _stuns.size()
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.237
	torus.outer_radius = 0.249
	torus.rings = 32
	torus.ring_segments = 6
	ring.mesh = torus
	ring.material_override = _stun_material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	indicator.add_child(ring)
	var star_material: StandardMaterial3D = _stun_material.duplicate()
	star_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	star_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in 3:
		var star := MeshInstance3D.new()
		star.name = "Star%d" % i
		star.mesh = _star_mesh
		star.material_override = star_material
		star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		indicator.add_child(star)
	indicator.visible = false
	add_child(indicator)
	return indicator


func _build_numbers() -> void:
	for i in number_pool:
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		# ПОДВОХ: без fixed_size размер числа задан в метрах мира (0.32 м при
		# font_size 64 и pixel_size 0.005). На дистанции камеры это читается
		# нормально, но SpringArm прижимает камеру к бойцу, когда за спиной
		# стена, - и то же число занимает пол-экрана. Драться спиной к стене
		# игрок будет постоянно, так что это не редкий случай.
		l.fixed_size = true
		l.font_size = 64
		l.outline_size = 18
		l.outline_modulate = Color(0, 0, 0, 0.85)
		l.pixel_size = number_pixel_size
		l.visible = false
		add_child(l)
		_numbers.append(l)
		# t < 0 означает «свободно». Ноль запускал бы анимацию всем числам
		# сразу на старте.
		_number_state.append({"t": -1.0, "from": Vector3.ZERO})


# ------------------------------------------------------------------
# Подписки
# ------------------------------------------------------------------

func _bind() -> void:
	_arena = _find_arena()
	if _arena == null or not _arena.visuals_enabled:
		return
	if not _pools.is_empty():
		return

	_build_pools()
	_build_numbers()
	set_process(true)

	for f in _arena.get_fighters():
		_bind_fighter(f)

	# Зомби переиспользуются из пула, поэтому подписка одна на всё время жизни
	var zroot := _arena.get_node_or_null("Zombies")
	if zroot != null:
		for z in zroot.get_children():
			if z is Zombie:
				_bind_zombie(z)

	_arena.potion_taken.connect(_on_potion_taken)


func _bind_fighter(f: Gladiator) -> void:
	f.dealt_damage.connect(_on_dealt_damage)
	f.damage_blocked.connect(_on_blocked.bind(f))
	f.took_damage.connect(_on_took_damage.bind(f))
	f.attack_contact.connect(_on_attack_started.bind(f))
	f.successful_parry.connect(_on_parry.bind(f))
	f.respawned.connect(clear_effects)


func _bind_zombie(z: Zombie) -> void:
	if z in _zombies:
		return
	z.damaged.connect(_on_zombie_damaged.bind(z))
	z.died.connect(_on_zombie_died)
	z.respawned.connect(_reset_stun.bind(_zombies.size()))
	_zombies.append(z)
	_stuns.append(_make_stun_indicator())
	_stun_active.append(false)


func _reset_stun(index: int) -> void:
	_stuns[index].visible = false
	_stun_active[index] = false


func _find_arena() -> Arena:
	var n: Node = get_parent()
	while n != null:
		if n is Arena:
			return n
		n = n.get_parent()
	return null


# ------------------------------------------------------------------
# События
# ------------------------------------------------------------------

func _on_dealt_damage(amount: float, target: Node3D, _type: int) -> void:
	if target == null or amount <= 0.0:
		return
	var at: Vector3 = target.global_position + Vector3.UP * 1.0
	# Blood is emitted once by Zombie.damaged, including non-player damage.
	spawn_number(at + Vector3.UP * 0.35, "%d" % roundi(amount), Color(1.0, 0.86, 0.5))


func _on_blocked(_absorbed: float, f: Gladiator) -> void:
	play(Kind.BLOCK, f.global_position + f.forward() * 0.6 + Vector3.UP * 1.1)


func _on_parry(_attacker: Node3D, f: Gladiator) -> void:
	spawn_number(f.global_position + Vector3.UP * 1.9, "ПАРИРОВАНИЕ", Color(0.55, 0.9, 1.0))
	play(Kind.STUN, f.global_position + f.guard_direction() * 0.6 + Vector3.UP * 1.2)


func _on_took_damage(amount: float, blocked: bool, f: Gladiator) -> void:
	if blocked or amount <= 0.0:
		return
	var at: Vector3 = f.global_position + Vector3.UP * 1.2
	play_blood(at)
	spawn_number(at + Vector3.UP * 0.3, "-%d" % roundi(amount), Color(1.0, 0.35, 0.3))


func _on_attack_started(type: int, f: Gladiator) -> void:
	if type == Gladiator.AttackType.KICK:
		play(Kind.DUST, f.global_position + f.forward() * 0.9 + Vector3.UP * 0.15)


func _on_zombie_damaged(amount: float, z: Zombie) -> void:
	if amount <= 0.0:
		return
	var height := 1.0
	var visual := z.get_node_or_null("Visuals") as Node3D
	if visual != null:
		height *= visual.scale.y
	play_blood(z.global_position + Vector3.UP * height)


func _on_zombie_died(z: Zombie) -> void:
	play(Kind.DEATH, z.global_position + Vector3.UP * 0.8)


func _on_potion_taken(healed: float) -> void:
	if _arena == null or healed <= 0.0:
		return
	for f in _arena.get_fighters():
		if f.is_alive():
			play(Kind.HEAL, f.global_position + Vector3.UP * 0.9)
			spawn_number(f.global_position + Vector3.UP * 1.9,
				"+%d" % roundi(healed), Color(0.45, 1.0, 0.55))
			break


# ------------------------------------------------------------------
# Воспроизведение
# ------------------------------------------------------------------

func play(kind: int, at: Vector3) -> void:
	var arr: Array = _pools.get(kind, [])
	if arr.is_empty():
		return
	var i: int = _next[kind]
	_next[kind] = (i + 1) % arr.size()

	var p: GPUParticles3D = arr[i]
	p.visible = true
	p.global_position = at
	p.restart()
	p.emitting = true


func play_blood(at: Vector3) -> void:
	if _bursts.is_empty():
		return
	play(Kind.HIT, at)
	var index := _next_burst
	_next_burst = (index + 1) % _bursts.size()
	var burst := _bursts[index]
	var camera := get_viewport().get_camera_3d()
	# Put the splash just outside the body, with normal depth testing so
	# blood cannot show through walls or the player's shield.
	var surface_offset := Vector3.ZERO
	if camera != null:
		surface_offset = (camera.global_position - at).normalized() * 0.3
	burst.global_position = at + surface_offset
	burst.scale = Vector3.ONE * 0.5
	burst.modulate = Color.WHITE
	burst.flip_h = index % 2 == 0
	burst.visible = true
	_burst_times[index] = 0.0


func clear_effects() -> void:
	for kind in _pools:
		for particle: GPUParticles3D in _pools[kind]:
			particle.emitting = false
			particle.visible = false
	for i in _bursts.size():
		_bursts[i].visible = false
		_burst_times[i] = -1.0
	for i in _numbers.size():
		_numbers[i].visible = false
		_number_state[i]["t"] = -1.0
	for i in _stuns.size():
		_reset_stun(i)


func spawn_number(at: Vector3, text: String, color: Color) -> void:
	if not show_damage_numbers or _numbers.is_empty():
		return
	var i := _next_number
	_next_number = (i + 1) % _numbers.size()

	var l := _numbers[i]
	l.text = text
	l.modulate = color
	# Небольшой разброс, иначе серия ударов рисует числа ровно друг на друге
	var jitter := Vector3(randf_range(-0.25, 0.25), 0.0, randf_range(-0.25, 0.25))
	l.global_position = at + jitter
	l.visible = true
	_number_state[i] = {"t": 0.0, "from": l.global_position}


func _process(delta: float) -> void:
	_update_bursts(delta)
	_update_stuns(delta)
	for i in _numbers.size():
		var st: Dictionary = _number_state[i]
		var t: float = st["t"]
		if t < 0.0:
			continue

		t += delta
		if t >= 0.9:
			_numbers[i].visible = false
			st["t"] = -1.0
			_number_state[i] = st
			continue

		var k := t / 0.9
		var l := _numbers[i]
		l.global_position = st["from"] + Vector3.UP * (0.9 * k)
		l.modulate.a = 1.0 - k * k     # держится, потом быстро гаснет
		st["t"] = t
		_number_state[i] = st


func _update_bursts(delta: float) -> void:
	for i in _bursts.size():
		if _burst_times[i] < 0.0:
			continue
		_burst_times[i] += delta
		var t := _burst_times[i] / BURST_LIFETIME
		if t >= 1.0:
			_bursts[i].visible = false
			_burst_times[i] = -1.0
			continue
		_bursts[i].scale = Vector3.ONE * lerpf(0.5, 1.05, 1.0 - pow(1.0 - t, 3.0))
		_bursts[i].modulate.a = 1.0 - smoothstep(0.25, 1.0, t)


func _update_stuns(delta: float) -> void:
	_stun_phase = fmod(_stun_phase + delta * 4.5, TAU)
	for i in _zombies.size():
		var z := _zombies[i]
		var active := is_instance_valid(z) and z.is_alive() and z.visible and z.state == Zombie.State.STAGGER
		var indicator := _stuns[i]
		indicator.visible = active
		if not active:
			_stun_active[i] = false
			continue
		var visual := z.get_node_or_null("Visuals") as Node3D
		var height_scale := visual.scale.y if visual != null else 1.0
		indicator.global_position = z.global_position + Vector3.UP * (1.8 * height_scale)
		indicator.scale = Vector3.ONE * height_scale
		if not _stun_active[i]:
			play(Kind.STUN, indicator.global_position)
			spawn_number(indicator.global_position + Vector3.UP * 0.2, "ОГЛУШЁН", Color(1.0, 0.72, 0.18))
		_stun_active[i] = true
		for star in 3:
			var angle := _stun_phase + TAU * star / 3.0
			indicator.get_child(star + 1).position = Vector3(cos(angle) * 0.255,
				sin(angle * 2) * 0.045, sin(angle) * 0.255)

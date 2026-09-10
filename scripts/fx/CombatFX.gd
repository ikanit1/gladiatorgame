class_name CombatFX
extends Node3D

## Визуальный отклик боя: частицы попаданий, искры блока, пыль, числа урона.
##
## Живёт внутри ветки Decor, поэтому при обучении отключается вместе с ней
## одним process_mode. Ни одна из этих штук не влияет на физику и наблюдения.
##
## Всё сделано пулами: эффект в бою срабатывает по несколько раз в секунду,
## а instantiate/queue_free на каждый удар - это мусор для сборщика ровно там,
## где нужен ровный кадр.

@export var pool_per_effect: int = 8
@export var number_pool: int = 12
@export var show_damage_numbers: bool = true

enum Kind { HIT, BLOCK, DUST, DEATH, HEAL }

var _pools: Dictionary = {}     # Kind -> Array[GPUParticles3D]
var _next: Dictionary = {}      # Kind -> int
var _numbers: Array[Label3D] = []
var _number_state: Array[Dictionary] = []
var _next_number: int = 0

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
		Kind.HIT: {"color": Color(0.75, 0.12, 0.12), "count": 14, "speed": 5.5,
			"life": 0.5, "size": 0.09, "gravity": -9.0, "spread": 55.0},
		Kind.BLOCK: {"color": Color(1.0, 0.86, 0.45), "count": 12, "speed": 6.5,
			"life": 0.35, "size": 0.06, "gravity": -6.0, "spread": 40.0},
		Kind.DUST: {"color": Color(0.78, 0.70, 0.55), "count": 7, "speed": 1.4,
			"life": 0.55, "size": 0.13, "gravity": -1.2, "spread": 80.0},
		Kind.DEATH: {"color": Color(0.42, 0.55, 0.32), "count": 22, "speed": 3.4,
			"life": 0.85, "size": 0.14, "gravity": -5.0, "spread": 90.0},
		Kind.HEAL: {"color": Color(0.4, 1.0, 0.55), "count": 14, "speed": 2.2,
			"life": 0.7, "size": 0.08, "gravity": 2.2, "spread": 35.0},
	}

	for kind in specs:
		var arr: Array[GPUParticles3D] = []
		for i in pool_per_effect:
			var p := _make_particles(specs[kind])
			add_child(p)
			arr.append(p)
		_pools[kind] = arr
		_next[kind] = 0


func _make_particles(spec: Dictionary) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.emitting = false
	p.one_shot = true
	p.explosiveness = 1.0        # весь залп в один кадр, а не струйка
	p.amount = int(spec["count"])
	p.lifetime = float(spec["life"])
	p.local_coords = false       # частицы остаются на месте удара, а не едут за бойцом

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

	var quad := QuadMesh.new()
	quad.size = Vector2(float(spec["size"]), float(spec["size"]))
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.vertex_color_use_as_albedo = true
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = qm
	p.draw_pass_1 = quad
	return p


func _build_numbers() -> void:
	for i in number_pool:
		var l := Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.font_size = 64
		l.outline_size = 18
		l.outline_modulate = Color(0, 0, 0, 0.85)
		l.pixel_size = 0.005
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
				z.damaged.connect(_on_zombie_damaged.bind(z))
				z.died.connect(_on_zombie_died)

	_arena.potion_taken.connect(_on_potion_taken)


func _bind_fighter(f: Gladiator) -> void:
	f.dealt_damage.connect(_on_dealt_damage)
	f.damage_blocked.connect(_on_blocked.bind(f))
	f.took_damage.connect(_on_took_damage.bind(f))
	f.attack_started.connect(_on_attack_started.bind(f))


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
	if target == null:
		return
	var at: Vector3 = target.global_position + Vector3.UP * 1.0
	play(Kind.HIT, at)
	spawn_number(at + Vector3.UP * 0.35, "%d" % roundi(amount), Color(1.0, 0.86, 0.5))


func _on_blocked(_absorbed: float, f: Gladiator) -> void:
	play(Kind.BLOCK, f.global_position + f.forward() * 0.6 + Vector3.UP * 1.1)


func _on_took_damage(amount: float, blocked: bool, f: Gladiator) -> void:
	if blocked or amount <= 0.0:
		return
	var at: Vector3 = f.global_position + Vector3.UP * 1.2
	play(Kind.HIT, at)
	spawn_number(at + Vector3.UP * 0.3, "-%d" % roundi(amount), Color(1.0, 0.35, 0.3))


func _on_attack_started(type: int, f: Gladiator) -> void:
	if type == Gladiator.AttackType.KICK:
		play(Kind.DUST, f.global_position + f.forward() * 0.9 + Vector3.UP * 0.15)


func _on_zombie_damaged(_amount: float, z: Zombie) -> void:
	play(Kind.HIT, z.global_position + Vector3.UP * 0.9)


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
	p.global_position = at
	p.restart()
	p.emitting = true


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

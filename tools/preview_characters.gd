extends Node3D

var fighters: Array[Node3D] = []
var elapsed := 0.0
var captured := false
var motion := false
var previous_stage := -1
var title: Label
var samples: Dictionary = {}

func _ready() -> void:
	var env := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("171e27")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("a7bcd1")
	settings.ambient_light_energy = 0.65
	settings.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.environment = settings
	add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -145, 0)
	key.light_color = Color("ffddb3")
	key.light_energy = 1.3
	key.shadow_enabled = true
	add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-25, 30, 0)
	rim.light_color = Color("8abfee")
	rim.light_energy = 1.4
	add_child(rim)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("303940")
	mat.roughness = 0.9
	ground.material_override = mat
	add_child(ground)
	var args := OS.get_cmdline_user_args()
	motion = "motion" in args
	var lineup := "lineup" in args
	for i in (4 if lineup else 2):
		var fighter: Node3D = load("res://scenes/Gladiator.tscn" if i == 0 else "res://scenes/Zombie.tscn").instantiate()
		fighter.position.x = (float(i) - (1.5 if lineup else 0.5)) * 1.65
		fighter.rotation_degrees.y = -15
		if i == 0:
			fighter.get_node("Brain").free()
		add_child(fighter)
		fighter.set_physics_process(false)
		if i == 0:
			fighter.get_node("PlayerInput").process_mode = Node.PROCESS_MODE_DISABLED
		else:
			fighter.health = fighter.max_health
			fighter.variant = i - 1
			fighter.respawned.emit()
			fighter.get_node("Visuals/HealthBar3D").hide()
		fighters.append(fighter)
		if motion:
			fighter.get_node("Visuals").set_process(false)
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(2.7 if lineup else 2.3, 2.4, -7.5 if lineup else -5.2)
	camera.look_at(Vector3(0, 1.0, 0))
	camera.fov = 37 if lineup else 35
	camera.current = true
	if motion:
		var canvas := CanvasLayer.new()
		add_child(canvas)
		title = Label.new()
		title.position = Vector2(40, 30)
		title.add_theme_font_size_override("font_size", 28)
		canvas.add_child(title)

func _process(delta: float) -> void:
	elapsed += delta
	if motion:
		animate_demo(delta)
		return
	if elapsed < 0.5 or captured:
		return
	captured = true
	for fighter in fighters:
		fighter.get_node("Visuals").set_process(false)
		fighter.get_node("Visuals")._process(1.0 / 60.0)
		if fighter is Zombie:
			fighter.get_node("Visuals/HealthBar3D").hide()
	await RenderingServer.frame_post_draw
	var args := OS.get_cmdline_user_args()
	var filename := "lineup" if "lineup" in args else "after"
	get_viewport().get_texture().get_image().save_png("res://tools/character_preview/%s.png" % filename)
	print("CHARACTER_PREVIEW: ", filename)
	get_tree().quit()

func animate_demo(delta: float) -> void:
	var g: Gladiator = fighters[0]
	var z: Zombie = fighters[1]
	var gv: Node3D = g.get_node("Visuals")
	var zv: Node3D = z.get_node("Visuals")
	var stage := 0
	if elapsed >= 1: stage = 1
	if elapsed >= 4: stage = 2
	if elapsed >= 5.5: stage = 3
	if elapsed >= 6.4: stage = 4
	if elapsed >= 7.3: stage = 5
	if elapsed >= 8.4: stage = 6
	if elapsed >= 10: stage = 7
	title.text = ["ПОКОЙ / ДЫХАНИЕ", "ПОХОДКА / СГИБАНИЕ КОЛЕНЕЙ", "БЛОК / ЗАМАХ ЗОМБИ",
		"МЕЧ / ВОЗВРАТ В СТОЙКУ", "ПИНОК", "РЕАКЦИЯ НА УДАР", "ПАДЕНИЕ", "ВОЗРОЖДЕНИЕ"][stage]
	g.velocity = Vector3(0, 0, -3.4) if stage == 1 else Vector3.ZERO
	z.velocity = Vector3(0, 0, -2.4) if stage == 1 else Vector3.ZERO
	g.is_blocking = stage == 2
	g.stun_time = 0.6 if stage == 5 else 0.0
	if stage == 2:
		var attack_t := fmod(elapsed - 4.0, z.attack_windup + z.attack_recover)
		z.state = Zombie.State.WINDUP if attack_t < z.attack_windup else Zombie.State.RECOVER
		z._timer = z.attack_windup - attack_t if attack_t < z.attack_windup else z.attack_windup + z.attack_recover - attack_t
	elif stage == 5:
		z.state = Zombie.State.STAGGER
	elif stage < 6:
		z.state = Zombie.State.CHASE if stage == 1 else Zombie.State.IDLE
	if stage != previous_stage:
		if stage == 3:
			g.attack_started.emit(Gladiator.AttackType.SWORD)
		if stage == 4:
			g.attack_started.emit(Gladiator.AttackType.KICK)
		if stage == 5:
			g.took_damage.emit(10, false)
			z.damaged.emit(10)
		if stage == 6:
			g._alive = false
			z.state = Zombie.State.DEAD
		if stage == 7:
			g._alive = true
			g.revived.emit(45)
			z.state = Zombie.State.IDLE
			z.respawned.emit()
		previous_stage = stage
	gv._process(delta)
	zv._process(delta)
	z.get_node("Visuals/HealthBar3D").hide()
	if elapsed >= [0.7, 2.5, 4.4, 5.62, 6.52, 7.6, 9.8, 10.7][stage] and not samples.has(stage):
		samples[stage] = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://_t/motion_%d.png" % stage)
	if elapsed >= 11.5:
		print("CHARACTER_MOTION: completed all 8 states")
		get_tree().quit()

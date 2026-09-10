extends SceneTree
## Interactive, deterministic showcase. -- --capture exports 30-fps frames.

var fighters: Array[Node3D] = []
var elapsed := 0.0
var frame := 0
var capture := false
var busy := false
var stage := -1
var swing := -1
var caption: Label

func _initialize() -> void:
	call_deferred("setup")

func setup() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	root.size = Vector2i(1280, 720)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("17212d")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("bdd7eb")
	env.environment.ambient_light_energy = 0.8
	world.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-38, -145, 0)
	key.light_energy = 1.4
	world.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, 40, 0)
	fill.light_color = Color("9cbeda")
	fill.light_energy = 0.8
	world.add_child(fill)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(100, 100)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("26323f")
	mat.roughness = 1
	ground.material_override = mat
	world.add_child(ground)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 3.5, -12)
	camera.look_at(Vector3(0, 1.3, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 6.2
	camera.current = true
	for i in 4:
		var actor: Node3D = load("res://scenes/Gladiator.tscn" if i == 0 else "res://scenes/Zombie.tscn").instantiate()
		if i == 0:
			actor.get_node("Brain").free()
			actor.get_node("PlayerInput").free()
		actor.position.x = (1.5 - i) * 2.45
		world.add_child(actor)
		actor.set_physics_process(false)
		if actor is Zombie:
			actor.set_variant(i - 1)
			actor.activate(actor.transform, null)
		var visual: Node3D = actor.get_node("Visuals")
		visual.set_process(false)
		visual.get_node("Sfx").process_mode = Node.PROCESS_MODE_DISABLED
		if actor is Zombie:
			visual.get_node("HealthBar3D").hide()
		fighters.append(actor)
		var label := Label3D.new()
		label.text = ["ГЛАДИАТОР", "ЗОМБИ", "БЕГУН", "ГРОМИЛА"][i]
		label.position = Vector3(actor.position.x, 3.1, 0)
		label.font_size = 40
		label.pixel_size = 0.005
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		world.add_child(label)
	var canvas := CanvasLayer.new()
	root.add_child(canvas)
	caption = Label.new()
	caption.position = Vector2(35, 30)
	caption.add_theme_font_size_override("font_size", 26)
	canvas.add_child(caption)
	if capture:
		DirAccess.make_dir_recursive_absolute("res://_t/combat_showcase")
		# Raw capture frames are not game textures; avoid importing hundreds.
		var ignore := FileAccess.open("res://_t/combat_showcase/.gdignore", FileAccess.WRITE)
		ignore.close()

func _process(delta: float) -> bool:
	if fighters.is_empty() or busy:
		return false
	var dt := 1.0 / 30.0 if capture else minf(delta, 0.05)
	var g: Gladiator = fighters[0]
	var next_stage := 0 if elapsed < 2 else (1 if elapsed < 3.5 else (2 if elapsed < 8.3 else (3 if elapsed < 9.4 else 4)))
	caption.text = ["ПОХОДКА · перенос веса и разные типы движения", "ЩИТ · IK руки и независимое прицеливание",
		"АТАКИ · замах → контакт → восстановление", "ПОПАДАНИЕ · реакция корпуса и оглушение", "ПАДЕНИЕ · завершение движения"][next_stage]
	if next_stage != stage:
		stage = next_stage
		if stage == 3:
			g.take_damage(10, g.position + Vector3(-1, 0, -1))
			for i in range(1, 4):
				var z: Zombie = fighters[i]
				z.stagger(0.8, z.position + Vector3(-1, 0, -1), 2.5)
		if stage == 4:
			g._die()
			for i in range(1, 4):
				fighters[i]._die()
	g.velocity = Vector3(0, 0, -3) if stage == 0 else Vector3.ZERO
	g.is_blocking = stage == 1
	g.intent_aim_direction = Vector3.FORWARD.rotated(Vector3.UP, sin((elapsed - 2) * 3) * 0.6) if stage == 1 else Vector3.ZERO
	if stage == 2:
		var next_swing := int((elapsed - 3.5) / 1.2)
		if next_swing != swing:
			swing = next_swing
			g._begin_attack(Gladiator.AttackType.SWORD)
			for i in range(1, 4):
				fighters[i]._begin_attack()
	g._tick_timers(dt)
	g._tick_combat(dt)
	for i in fighters.size():
		var actor := fighters[i]
		if actor is Zombie:
			actor.velocity = Vector3(0, 0, -actor.move_speed * 0.85) if stage == 0 else Vector3.ZERO
			if stage == 0:
				actor.state = Zombie.State.CHASE
			elif stage == 1:
				actor.state = Zombie.State.IDLE
			actor.combat_animation.step(dt, 1)
		actor.get_node("Visuals")._process(dt)
		if actor is Zombie:
			actor.get_node("Visuals/HealthBar3D").hide()
	elapsed += dt
	if capture:
		busy = true
		save_frame()
	elif elapsed > 10.8:
		quit()
	return false

func save_frame() -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://_t/combat_showcase/frame%04d.png" % frame)
	frame += 1
	busy = false
	if elapsed > 10.8:
		busy = true
		print("COMBAT_SHOWCASE: %d frames" % frame)
		quit()

extends SceneTree
## Run with --script res://tools/preview_sword_swings.gd to compare all swings.
## Add -- --capture to save a contact-pose image and exit.

var visuals: Array[Node3D] = []
var elapsed := 0.0
var captured := false
var capture := false

func _initialize() -> void:
	call_deferred("setup")

func setup() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	root.size = Vector2i(1440, 720)
	var stage := Node3D.new()
	root.add_child(stage)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("19212c")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("b1c6e2")
	world.environment.ambient_light_energy = 0.65
	stage.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -35, 0)
	light.light_energy = 1.6
	stage.add_child(light)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(0, 3.4, -11)
	camera.look_at(Vector3(0, 1.1, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 5.2
	camera.current = true
	var names := ["ДИАГОНАЛЬНЫЙ", "БОКОВОЙ", "ОБРАТНЫЙ", "СВЕРХУ"]
	for i in names.size():
		var g: Gladiator = load("res://scenes/Gladiator.tscn").instantiate()
		g.get_node("Brain").free()
		g.get_node("PlayerInput").free()
		g.position.x = (1.5 - i) * 2.3
		stage.add_child(g)
		g.set_physics_process(false)
		var v: Node3D = g.get_node("Visuals")
		v.set_process(false)
		v.get_node("Sfx").process_mode = Node.PROCESS_MODE_DISABLED
		visuals.append(v)
		var label := Label3D.new()
		label.text = names[i]
		label.position = Vector3(g.position.x, 2.8, 0)
		label.font_size = 42
		label.pixel_size = 0.006
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		stage.add_child(label)
	start_swings()

func start_swings() -> void:
	for i in visuals.size():
		var v := visuals[i]
		v._next_sword_swing = i
		v.get_parent()._begin_attack(Gladiator.AttackType.SWORD)
		if capture:
			v.get_parent()._tick_combat(v.get_parent().sword_windup)
		v._process(0.0)

func _process(delta: float) -> bool:
	if visuals.is_empty():
		return false
	if capture:
		if not captured:
			captured = true
			capture_frame()
		return false
	elapsed += delta
	if elapsed > 1.2:
		elapsed = 0.0
		start_swings()
	for v in visuals:
		v.get_parent()._tick_combat(delta * 0.55)
		v._process(delta * 0.55)
	return false

func capture_frame() -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://_t")
	root.get_texture().get_image().save_png("res://_t/sword_swings.png")
	print("SWORD_PREVIEW: res://_t/sword_swings.png")
	quit()

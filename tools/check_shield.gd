extends Node3D

var fighters: Array[Gladiator] = []
var frames := 0

func _ready() -> void:
	var env := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.09, 0.11, 0.15)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.8, 0.85, 1.0)
	settings.ambient_light_energy = 0.8
	settings.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.environment = settings
	add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, -145, 0)
	key.light_energy = 1.5
	add_child(key)
	for i in range(3):
		var fighter: Gladiator = load("res://scenes/Gladiator.tscn").instantiate()
		fighter.position.x = (i - 1) * 1.8
		add_child(fighter)
		fighter.set_physics_process(false)
		fighter.get_node("PlayerInput").process_mode = Node.PROCESS_MODE_DISABLED
		fighter.is_blocking = i == 1
		if i == 2:
			fighter.velocity = Vector3(0, 0, -3)
		fighters.append(fighter)
		var label := Label3D.new()
		label.text = ["ПОКОЙ", "БЛОК", "ДВИЖЕНИЕ"][i]
		label.position = Vector3(fighter.position.x, 2.05, 0)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = 40
		label.pixel_size = 0.004
		add_child(label)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(2.2, 2.25, -6.5)
	cam.look_at(Vector3(0, 1.1, 0))
	cam.fov = 48
	cam.current = true

func _process(_delta: float) -> void:
	frames += 1
	if frames != 50:
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tools/diagnostics/shield_fixed.png")
	var failures := 0
	for fighter in fighters:
		var visual := fighter.get_node("Visuals")
		var body: Node3D = visual.get_node("Body")
		var arm: Node3D = visual.get_node("Body/ArmL")
		var model: Node3D = visual.get_node("Body/ArmL/Shield/ShieldModel")
		for pose in [Vector3(0, 0, 7), Vector3(78, 0, 26), Vector3(45, 25, -30), Vector3(-25, 10, 7)]:
			arm.rotation_degrees = pose
			visual._sync_shield()
			var basis := (body.global_basis.inverse() * model.global_basis).orthonormalized()
			if fighter == fighters[0]:
				print("pose=", pose, " face=", basis.x, " up=", basis.y, " local=", model.basis)
			if basis.x.dot(Vector3.FORWARD) < 0.9999 or basis.y.dot(Vector3.UP) < 0.9999:
				failures += 1
	print("SHIELD: 12 orientation checks, ", failures, " failures; scale=0.85")
	get_tree().quit(0 if failures == 0 else 1)

extends Node3D

func _ready() -> void:
	var env := WorldEnvironment.new()
	var game: Node = load("res://scenes/Game.tscn").instantiate()
	var settings: Environment = game.get_node("WorldEnvironment").environment.duplicate()
	game.free()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.055, 0.075, 0.105)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.65, 0.72, 0.85)
	settings.ambient_light_energy = 0.65
	env.environment = settings
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -25, 0)
	light.light_color = Color(1.0, 0.84, 0.67)
	light.light_energy = 1.5
	light.shadow_enabled = true
	add_child(light)
	var room := DungeonRoom.new()
	add_child(room)
	room.setup({"shape": "квадратная", "grid_w": 7, "grid_d": 7, "floor_color": Color(0.6, 0.55, 0.47)}, Vector3.ZERO, -1, 0, true)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(4.8, 3.5, 5.7)
	cam.fov = 65
	cam.look_at(Vector3(0, 1.3, -6))
	cam.current = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for i in range(30):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://assets/higgsfield/preview/fortress_room.png")
	print("Saved fortress_room.png")
	room.free()
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(200, 200)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.07, 0.09, 0.12)
	floor_mat.roughness = 0.85
	floor_mesh.material = floor_mat
	var ground := MeshInstance3D.new()
	ground.mesh = floor_mesh
	add_child(ground)
	var index := 0
	for filename in ["fortress_pillar", "bronze_brazier", "iron_portcullis"]:
		var model: Node3D = load("res://assets/higgsfield/models/" + filename + ".tscn").instantiate()
		model.position.x = (index - 1) * 2.15
		add_child(model)
		index += 1
	cam.position = Vector3(4.5, 3.4, 8.0)
	cam.fov = 42
	cam.look_at(Vector3(0.1, 1.4, 0))
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://assets/higgsfield/preview/fortress_models.png")
	get_tree().quit()

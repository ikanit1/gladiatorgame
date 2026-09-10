extends SceneTree

var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		push_error(label)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		quit(2)
		return
	var game: Node3D = load("res://scenes/Game.tscn").instantiate()
	root.add_child(game)
	game.arena.set("_wave_timer", 1000.0)
	# Let the OS settle startup focus before testing captured gameplay input.
	await create_timer(0.3).timeout
	if paused:
		game._on_primary()
	for i in range(5):
		await physics_frame
	var fighter: Gladiator = game.arena.gladiator
	check(fighter.human_movement, "Game activates manual controller")
	if game.arena.ally != null:
		check(not game.arena.ally.human_movement, "Companion stays on AI movement")
	var start := fighter.position
	Input.action_press("g_forward")
	for i in range(12):
		await physics_frame
	Input.action_release("g_forward")
	check(fighter.position.distance_to(start) > 0.35, "Real input moves character in Game scene")
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	Input.parse_input_event(mouse.duplicate())
	for i in range(3):
		await physics_frame
	check(fighter.sword_cd > 0.5, "LMB reaches gameplay through HUD input routing")
	mouse.pressed = false
	Input.parse_input_event(mouse.duplicate())
	mouse.button_index = MOUSE_BUTTON_RIGHT
	mouse.pressed = true
	Input.parse_input_event(mouse.duplicate())
	for i in range(23):
		await physics_frame
	check(fighter.is_blocking, "RMB holds shield after attack recovery")
	game.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await process_frame
	check(paused and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "Focus loss pauses Game and releases cursor")
	check(not fighter.intent_block and not fighter.intent_sword, "Focus loss clears held/queued intent")
	mouse.pressed = false
	Input.parse_input_event(mouse.duplicate())
	game._on_primary()
	await physics_frame
	await process_frame
	check(not paused and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "Resume restores mouse capture")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tools/controls_game.png")
	for player in game.find_children("*", "AudioStreamPlayer", true, false):
		player.stop()
	for player in game.find_children("*", "AudioStreamPlayer3D", true, false):
		player.stop()
	game.free()
	await create_timer(0.15).timeout
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print("GAME INPUT: ", failures, " failures")
	quit(0 if failures == 0 else 1)

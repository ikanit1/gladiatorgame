extends Node

func _ready() -> void:
	var game: Node = load("res://scenes/Game.tscn").instantiate()
	add_child(game)
	# Allow normal combat, then inspect a live frame with the actual room lights.
	await get_tree().create_timer(0.2).timeout
	if get_tree().paused:
		game._on_primary()
	game.arena.human_control = false
	game.arena.gladiator.get_node("PlayerInput").process_mode = Node.PROCESS_MODE_DISABLED
	game.arena.gladiator.max_health = 10000
	game.arena.gladiator.health = 10000
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for frame in 600:
		await get_tree().physics_frame
		if get_tree().paused:
			game._on_primary()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://tools/character_preview/game.png")
	print("CHARACTER_GAME: 600 physics frames; FPS=", Engine.get_frames_per_second(),
		" draw_calls=", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	get_tree().quit()

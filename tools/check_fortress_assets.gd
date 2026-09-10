extends SceneTree

func _initialize() -> void:
	call_deferred("run_checks")

func collision_layout(node: Node, result: Array) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			result.append([child.position, child.shape.size])
		collision_layout(child, result)

func run_checks() -> void:
	var cases := 0
	for shape in RoomGenerator.SHAPES:
		for side in range(4):
			var cfg := {"shape": shape, "grid_w": 9, "grid_d": 9}
			var visual := DungeonRoom.new()
			var plain := DungeonRoom.new()
			root.add_child(visual)
			root.add_child(plain)
			visual.setup(cfg, Vector3.ZERO, DungeonRoom.opposite_side(side), side, true)
			plain.setup(cfg, Vector3.ZERO, DungeonRoom.opposite_side(side), side, false)
			var a: Array = []
			var b: Array = []
			collision_layout(visual, a)
			collision_layout(plain, b)
			assert(a == b, "Decor changed physics")
			assert(plain.get_node_or_null("WallVisual") == null)
			assert(visual.get_node("ClosedDoor").get_child_count() == 1)
			visual.set_exit_open(true)
			await process_frame
			assert(not visual.get_node("ClosedDoor").visible)
			assert(visual.get_node("WallCollision/ExitDoorBlocker").disabled)
			visual.set_exit_open(false)
			await process_frame
			assert(visual.get_node("ClosedDoor").visible)
			assert(not visual.get_node("WallCollision/ExitDoorBlocker").disabled)
			visual.free()
			plain.free()
			cases += 1
	for model in ["fortress_pillar", "bronze_brazier", "iron_portcullis"]:
		var scene := load("res://assets/higgsfield/models/" + model + ".glb") as PackedScene
		assert(scene != null)
		var node := scene.instantiate()
		assert(node.find_children("*", "MeshInstance3D").size() > 0)
		node.free()
	var game: Node = load("res://scenes/Game.tscn").instantiate()
	root.add_child(game)
	for frame in range(120):
		await process_frame
	for player in game.find_children("*", "AudioStreamPlayer", true, false):
		player.stop()
	for player in game.find_children("*", "AudioStreamPlayer3D", true, false):
		player.stop()
	game.free()
	await create_timer(0.15).timeout
	print("PASS: ", cases, " room layouts, identical collisions, both gate states, headless decor suppression, 3 GLB imports, game smoke.")
	quit()

extends SceneTree

func _initialize() -> void:
	var game: Node = load("res://scenes/Game.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	var gladiator: Node = game.get_node_or_null("Gladiator")
	var cape: Node = gladiator.get_node_or_null("Body/CapeRoot") if gladiator != null else null
	var skirt: Node = gladiator.get_node_or_null("Body/Skirt") if gladiator != null else null
	print("visual_smoke: game=%s cape=%s skirt=%s" % [game != null, cape != null, skirt != null])
	quit()

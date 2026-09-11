extends Node

## Потолок не должен появляться при обучении: там нет камеры, а лишние
## коллизионные формы умножаются на число параллельных арен.

func _ready() -> void:
	for show_visuals in [true, false]:
		var room := DungeonRoom.new()
		add_child(room)
		room.setup(RoomGenerator.geometry(RandomNumberGenerator.new()),
			Vector3.ZERO, {}, show_visuals)
		var body := room.get_node_or_null("CeilingCollision")
		var vis := room.get_node_or_null("CeilingVisual")
		var lamps := 0
		if vis != null:
			for c in vis.get_children():
				if c is OmniLight3D:
					lamps += 1
		print("visuals_enabled=%s -> потолок: коллизия=%s меш=%s ламп=%d" % [
			show_visuals, body != null, vis != null, lamps])
		room.queue_free()
		await get_tree().process_frame
	get_tree().quit()

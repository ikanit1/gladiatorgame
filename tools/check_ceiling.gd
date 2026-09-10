extends Node

## Снимки комнаты с потолком на трёх углах наклона камеры.
## Потолок влияет сразу на две вещи: за него цепляется SpringArm камеры,
## и он же отрезает прямой солнечный свет.

const OUT := "res://tools/ui_preview/"

var _rig: Node3D


func _ready() -> void:
	var game: Node = load("res://scenes/Game.tscn").instantiate()
	add_child(game)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _settle(120)

	_rig = game.get_node_or_null("CameraRig")
	if _rig == null:
		print("ПРОВАЛ: нет CameraRig")
		get_tree().quit(1)
		return

	for spec in [[-0.28, "ceil_normal"], [-0.90, "ceil_down"], [0.35, "ceil_up"]]:
		_rig.set("_pitch", float(spec[0]))
		await _settle(20)
		var cam: Camera3D = _rig.get_node_or_null("Camera3D")
		var dist := 0.0
		if cam != null:
			dist = cam.global_position.distance_to(_rig.global_position)
		print("наклон %+.2f рад: длина штанги %.2f м" % [float(spec[0]), dist])
		_shot(str(spec[1]) + ".png")

	get_tree().quit()


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shot(name: String) -> void:
	get_viewport().get_texture().get_image().save_png(OUT + name)

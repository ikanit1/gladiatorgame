extends Node

## Проверка: полоса над зомби скрыта при полном здоровье, появляется после
## урона и при этом снова начинает разворачиваться к камере.

func _ready() -> void:
	var game: Node = load("res://scenes/Game.tscn").instantiate()
	add_child(game)
	for _i in range(60):
		await get_tree().process_frame

	var arena = game.get("arena")
	var zombies = arena.get_alive_zombies()
	if zombies.is_empty():
		print("ПРОВАЛ: на арене нет зомби")
		get_tree().quit(1)
		return

	var z = zombies[0]
	var bar = z.get_node_or_null("Visuals/HealthBar3D")
	if bar == null:
		for child in z.find_children("HealthBar3D", "", true, false):
			bar = child
			break
	if bar == null:
		print("ПРОВАЛ: не найден узел HealthBar3D")
		get_tree().quit(1)
		return

	var whole: bool = bar.visible
	var whole_proc: bool = bar.is_processing()

	z.take_damage(20.0, z.global_position + Vector3.FORWARD)
	for _i in range(6):
		await get_tree().process_frame

	var hurt: bool = bar.visible
	var hurt_proc: bool = bar.is_processing()

	print("целый зомби:  полоса видна=%s  разворот=%s   (ожидалось нет/нет)" % [whole, whole_proc])
	print("раненый:      полоса видна=%s  разворот=%s   (ожидалось да/да)" % [hurt, hurt_proc])
	var ok: bool = not whole and not whole_proc and hurt and hurt_proc
	print("ИТОГ: " + ("ок" if ok else "ПРОВАЛ"))
	get_tree().quit(0 if ok else 1)

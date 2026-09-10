extends Node

## Проверка перед обучением: размер наблюдения и реальный состав волн.

func _ready() -> void:
	var world: Node = load("res://scenes/Training.tscn").instantiate()
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame

	var arena: Arena = world.get("arenas")[0]
	var brain = arena.gladiator.get_node_or_null("Brain")
	if brain == null:
		for c in arena.gladiator.get_children():
			if c.has_method("get_observation_size"):
				brain = c
	print("наблюдений: %d  (ожидалось %d)" % [
		brain.get_observation_size(), GladiatorBrain.observation_size_for(16)])
	print("variants_enabled в арене обучения: %s" % arena.variants_enabled)

	# Прогоняем счётчик волн и считаем, кого выдаёт _pick_variant
	var counts := {0: 0, 1: 0, 2: 0}
	for wave in range(1, 21):
		arena.run_wave_index = wave
		arena.wave_index = wave
		for i in range(200):
			var v: int = arena.call("_pick_variant")
			counts[v] = int(counts[v]) + 1
	var total := 4000.0
	print("состав за 20 волн: обычных %.0f%%, бегунов %.0f%%, громил %.0f%%" % [
		counts[0] / total * 100.0, counts[1] / total * 100.0, counts[2] / total * 100.0])

	# Отдельно: комната игры даёт 2-4 волны, и раньше на этом громилы терялись
	var per_room := {0: 0, 1: 0, 2: 0}
	arena.wave_index = 2
	for wave in range(1, 13):
		arena.run_wave_index = wave
		for i in range(200):
			var v: int = arena.call("_pick_variant")
			per_room[v] = int(per_room[v]) + 1
	print("при wave_index=2 (вторая волна комнаты), забег до 12 волн:")
	print("   обычных %.0f%%, бегунов %.0f%%, громил %.0f%%" % [
		per_room[0] / 2400.0 * 100.0, per_room[1] / 2400.0 * 100.0, per_room[2] / 2400.0 * 100.0])
	get_tree().quit()

extends SfxPlayer

## Звуки самой арены (гонг на старте волны). Живёт в ветке Decor,
## поэтому при visuals_enabled = false отключается вместе с ней.

const SND_WAVE := preload("res://audio/wave_start.wav")
const SND_POTION := preload("res://audio/potion_pickup.wav")
const SND_POTION_SPAWN := preload("res://audio/potion_spawn.wav")


func _ready() -> void:
	super._ready()
	var arena := _find_arena()
	if arena != null:
		arena.wave_started.connect(_on_wave_started)
		arena.potion_taken.connect(_on_potion_taken)
		arena.potion_spawned.connect(_on_potion_spawned)


func _find_arena() -> Arena:
	var n: Node = get_parent()
	while n != null:
		if n is Arena:
			return n
		n = n.get_parent()
	return null


func _on_wave_started(_index: int, _count: int) -> void:
	play(SND_WAVE, -8.0, 0.03)


func _on_potion_taken(_healed: float) -> void:
	play(SND_POTION, -2.0, 0.06)


func _on_potion_spawned(_potion: Potion) -> void:
	play(SND_POTION_SPAWN, -14.0, 0.1)

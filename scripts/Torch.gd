extends Node3D

## Мерцающий факел. Чистая математика на шуме синусов - без Timer и без Tween,
## чтобы четыре факела не стоили ничего заметного.

@export var base_energy: float = 3.2
@export var flicker_amount: float = 0.45
@export var flicker_speed: float = 7.0

@onready var _light: OmniLight3D = $Light
@onready var _flame: MeshInstance3D = $Flame

var _t: float = 0.0


func _ready() -> void:
	# Разводим фазы, иначе все факелы мерцают синхронно и это сразу заметно
	_t = randf() * 100.0


func _process(delta: float) -> void:
	_t += delta * flicker_speed
	var f := sin(_t) * 0.6 + sin(_t * 2.37) * 0.3 + sin(_t * 5.11) * 0.1

	_light.light_energy = base_energy * (1.0 + f * flicker_amount)
	var s := 1.0 + f * 0.18
	_flame.scale = Vector3(s, 1.0 + f * 0.3, s)

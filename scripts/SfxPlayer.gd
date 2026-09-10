class_name SfxPlayer
extends Node3D

## Пул позиционных источников звука.
##
## Зачем пул: один AudioStreamPlayer3D обрывает сам себя при повторном play().
## В бою удары идут чаще, чем затухает предыдущий звук, и без пула половина
## звуков просто пропадает.
##
## Узел живёт внутри визуальной ветки, поэтому при headless-обучении
## отключается вместе с ней и ничего не стоит.

@export var voices: int = 4
@export var max_distance: float = 45.0
@export var unit_size: float = 8.0

var _pool: Array[AudioStreamPlayer3D] = []
var _next: int = 0


func _ready() -> void:
	for i in voices:
		var p := AudioStreamPlayer3D.new()
		p.max_distance = max_distance
		p.unit_size = unit_size
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_pool.append(p)


## pitch_jitter обязателен для часто повторяющихся звуков: одинаковый питч
## подряд слышится как заедающая пластинка, а не как серия ударов.
func play(stream: AudioStream, volume_db: float = 0.0, pitch_jitter: float = 0.12) -> void:
	if stream == null or _pool.is_empty():
		return

	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()

	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = randf_range(1.0 - pitch_jitter, 1.0 + pitch_jitter)
	p.play()

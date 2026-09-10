extends Node3D

## Полоска здоровья над противником.
##
## Billboard делается скриптом, а не флагом материала: материальный billboard
## разворачивает меш уже в шейдере, поэтому масштабирование родителя (чем мы
## и заполняем полоску) даёт кривой результат.

@onready var _fill_pivot: Node3D = $FillPivot

var _cam: Camera3D


func set_ratio(r: float) -> void:
	_fill_pivot.scale.x = clampf(r, 0.0, 1.0)


func _process(_delta: float) -> void:
	if _cam == null or not is_instance_valid(_cam):
		_cam = get_viewport().get_camera_3d()
		if _cam == null:
			return

	# Разворачиваем к камере, не трогая позицию и масштаб заполнения
	var t := global_transform
	t.basis = _cam.global_transform.basis
	global_transform = t

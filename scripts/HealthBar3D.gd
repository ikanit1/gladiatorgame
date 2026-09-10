extends Node3D

## Полоска здоровья над противником.
##
## Billboard делается скриптом, а не флагом материала: материальный billboard
## разворачивает меш уже в шейдере, поэтому масштабирование родителя (чем мы
## и заполняем полоску) даёт кривой результат.

@onready var _fill_pivot: Node3D = $FillPivot

var _cam: Camera3D


## Полоса показывается только у раненого противника.
##
## У целого зомби она не несёт никаких сведений, зато арена из-за неё
## превращается в частокол красных прямоугольников, сквозь который не видно,
## кто на самом деле опасен. Ноль в scale.x недопустим: нулевой масштаб
## вырождает базис, и Godot ругается на невалидную матрицу.
func set_ratio(r: float) -> void:
	r = clampf(r, 0.0, 1.0)
	_fill_pivot.scale.x = maxf(r, 0.0001)
	visible = r < 0.995


## Разворот к камере невидимой полосе не нужен: при двух десятках зомби это
## два десятка лишних пересчётов базиса каждый кадр.
##
## Слушаем именно уведомление, а не переключаем обработку рядом с каждой
## записью в visible: полосу прячут и показывают из трёх разных мест
## ZombieVisuals (жизнь, смерть, возрождение), и любая новая точка вызова
## иначе снова оставила бы полосу видимой, но неповорачивающейся.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		set_process(is_visible_in_tree())


func _process(_delta: float) -> void:
	if _cam == null or not is_instance_valid(_cam):
		_cam = get_viewport().get_camera_3d()
		if _cam == null:
			return

	# Разворачиваем к камере, не трогая позицию и масштаб заполнения
	var t := global_transform
	t.basis = _cam.global_transform.basis
	global_transform = t

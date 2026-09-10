extends Camera3D

## Камера, следящая за гладиатором. Статичная камера на всю арену делает
## персонажей размером в несколько пикселей - разглядеть блок или замах
## невозможно, а это главный инструмент отладки поведения агента.

@export var target_path: NodePath
@export var offset: Vector3 = Vector3(0.0, 10.5, 10.5)
@export var follow_speed: float = 5.0
@export var look_height: float = 1.1

var _target: Node3D
var _look_at: Vector3


func _ready() -> void:
	if target_path != NodePath():
		set_target(get_node_or_null(target_path) as Node3D)


## Цель можно назначить и снаружи - игровая сцена собирает арену кодом,
## и на момент _ready() камеры гладиатора ещё не существует.
func set_target(node: Node3D) -> void:
	_target = node
	set_process(node != null)
	if node == null:
		return
	global_position = node.global_position + offset
	_look_at = node.global_position + Vector3.UP * look_height
	look_at(_look_at, Vector3.UP)


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return

	# Экспоненциальное сглаживание: не зависит от частоты кадров,
	# в отличие от простого lerp(a, b, speed * delta)
	var k := 1.0 - exp(-follow_speed * delta)

	global_position = global_position.lerp(_target.global_position + offset, k)
	_look_at = _look_at.lerp(_target.global_position + Vector3.UP * look_height, k)
	look_at(_look_at, Vector3.UP)

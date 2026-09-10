class_name Potion
extends Node3D

## Лечебное зелье на арене.
##
## Намеренно НЕ Area3D: подбор проверяется ареной по расстоянию. Четыре
## постоянно мониторящих Area3D на арену при сотне арен в обучении - это
## тысячи лишних проверок пересечений ради одного сравнения дистанций.
##
## Как и зомби, зелья переиспользуются из пула: никаких instantiate/queue_free
## на каждом эпизоде.

@export var heal_amount: float = 30.0
@export var bob_height: float = 0.12
@export var bob_speed: float = 2.2
@export var spin_speed_deg: float = 70.0

var _active: bool = false
var _phase: float = 0.0
var _base_y: float = 0.0

@onready var _visual: Node3D = $Visual


func _ready() -> void:
	_phase = randf() * TAU     # чтобы зелья не парили синхронно
	if not _active:
		deactivate()


func _process(delta: float) -> void:
	if not _active:
		return
	_phase += delta * bob_speed
	_visual.position.y = sin(_phase) * bob_height
	_visual.rotate_y(deg_to_rad(spin_speed_deg) * delta)


func activate(at: Vector3) -> void:
	global_position = at
	_base_y = at.y
	_active = true
	visible = true
	set_process(true)


func deactivate() -> void:
	_active = false
	visible = false
	set_process(false)
	global_position = Vector3(0.0, -100.0, 0.0)


func is_active() -> bool:
	return _active

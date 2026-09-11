class_name Pickup
extends Node3D

## Подбираемый предмет: монета, ключ, бомба.
##
## Сделан по образцу Potion: пул, activate/deactivate, подбор сравнением
## дистанций в хозяине пула, а не через Area3D. Area3D на десятке монет в
## каждой комнате это десяток лишних тел в физическом мире на кадр.

enum Kind { COIN, KEY, BOMB }

const COLORS := {
	Kind.COIN: Color(0.96, 0.78, 0.26),
	Kind.KEY: Color(0.82, 0.86, 0.92),
	Kind.BOMB: Color(0.22, 0.22, 0.26),
}

@export var spin_speed: float = 2.2
@export var bob_height: float = 0.12

var kind: int = Kind.COIN

var _active: bool = false
var _time: float = 0.0
var _base_y: float = 0.0
var _mesh: MeshInstance3D = null
var _material: StandardMaterial3D = null


func _ready() -> void:
	_mesh = get_node_or_null("Mesh") as MeshInstance3D
	if _mesh != null and _mesh.mesh != null:
		# Меш общий для всего пула - материал копируем, иначе смена вида
		# одной монеты перекрасит все.
		_material = StandardMaterial3D.new()
		_material.emission_enabled = true
		_material.emission_energy_multiplier = 1.4
		_mesh.material_override = _material
	deactivate()


func _process(delta: float) -> void:
	if not _active:
		return
	_time += delta
	rotate_y(spin_speed * delta)
	position.y = _base_y + sin(_time * 3.0) * bob_height


func activate(new_kind: int, at: Vector3) -> void:
	kind = new_kind
	global_position = at + Vector3.UP * 0.45
	_base_y = position.y
	_time = 0.0
	_active = true
	visible = true
	set_process(true)
	if _material != null:
		var color: Color = COLORS.get(kind, COLORS[Kind.COIN])
		_material.albedo_color = color
		_material.emission = color


func deactivate() -> void:
	_active = false
	visible = false
	set_process(false)
	position = Vector3(0.0, -100.0, 0.0)


func is_active() -> bool:
	return _active

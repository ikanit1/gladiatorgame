class_name Chest
extends Node3D

## Сундук. Сам награду не выдаёт: эмитит opened, а что положить внутрь,
## решает тот, кто показывает оверлей выбора.

enum Kind { COMMON, LOCKED, BOSS }

signal opened(kind: int)

const COLORS := {
	Kind.COMMON: Color(0.72, 0.55, 0.26),
	Kind.LOCKED: Color(0.82, 0.66, 0.30),
	Kind.BOSS: Color(0.78, 0.30, 0.34),
}

## На таком расстоянии сундук предлагает себя открыть.
const REACH := 2.0

var kind: int = Kind.COMMON

var _open: bool = false
var _lid: MeshInstance3D = null


func _ready() -> void:
	_lid = get_node_or_null("Lid") as MeshInstance3D
	_apply_look()


func setup(new_kind: int) -> void:
	kind = new_kind
	_open = false
	_apply_look()


func _apply_look() -> void:
	if _lid == null:
		return
	var material := StandardMaterial3D.new()
	var color: Color = COLORS.get(kind, COLORS[Kind.COMMON])
	material.albedo_color = color
	material.emission_enabled = not _open
	material.emission = color
	material.emission_energy_multiplier = 0.8
	_lid.material_override = material
	# Открытая крышка откинута: видно, что сундук уже выпотрошен.
	_lid.rotation_degrees.x = -80.0 if _open else 0.0


func is_open() -> bool:
	return _open


func requires_key() -> bool:
	return kind == Kind.LOCKED


## Может ли боец открыть сундук прямо сейчас.
func can_open(state: RunState, from: Vector3) -> bool:
	if _open:
		return false
	if global_position.distance_to(from) > REACH:
		return false
	if requires_key() and state.keys <= 0:
		return false
	return true


## Открывает сундук, списав ключ, если он нужен. Возвращает false, если
## открыть нельзя - вызывающий на этом показывает подсказку.
func open(state: RunState, from: Vector3) -> bool:
	if not can_open(state, from):
		return false
	if requires_key() and not state.use_key():
		return false
	_open = true
	_apply_look()
	opened.emit(kind)
	return true

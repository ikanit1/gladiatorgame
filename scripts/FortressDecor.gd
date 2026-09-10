extends RefCounted

## Visual-only dressing. Every prop stays within the existing wall thickness.
const PILLAR := preload("res://assets/higgsfield/models/fortress_pillar.tscn")
const BRAZIER := preload("res://assets/higgsfield/models/bronze_brazier.tscn")
const GATE := preload("res://assets/higgsfield/models/iron_portcullis.tscn")
const TORCH := preload("res://scenes/Torch.tscn")
const PV := preload("res://scripts/ProceduralVisuals.gd")

static func wall_detail(root: Node3D, center: Vector3, side: int, cell: Vector2i) -> void:
	var along_x := side < 2
	var trim := preload("res://materials/m_stone_dark.tres")
	var cap_size := Vector3(2.0, 0.13, 0.62) if along_x else Vector3(0.62, 0.13, 2.0)
	PV.box(root, "WallCornice", cap_size, center + Vector3.UP * 1.46, trim)
	PV.box(root, "WallFooting", cap_size * Vector3(1, 1.4, 1), center + Vector3.DOWN * 1.39, trim)
	var axis := cell.x if along_x else cell.y
	if posmod(axis, 4) != 2:
		return
	var column := PILLAR.instantiate() as Node3D
	column.name = "WallPillar"
	# The widest foot is 0.72 m. Scaling to 0.56 m keeps it inside a 0.6 m wall.
	column.scale = Vector3(0.78, 1.0, 0.78)
	column.position = center + Vector3.DOWN * 1.5
	root.add_child(column)

static func entrance_details(root: Node3D, center: Vector3, side: int) -> void:
	var tangent := Vector3.RIGHT if side < 2 else Vector3.BACK
	for sign_value in [-1.0, 1.0]:
		var prop := BRAZIER.instantiate() as Node3D
		prop.name = "GateBrazier"
		prop.scale = Vector3(0.64, 0.85, 0.64)
		prop.position = center + tangent * sign_value * 1.85
		root.add_child(prop)
		var torch := TORCH.instantiate() as Node3D
		torch.name = "BrazierFlame"
		torch.position = prop.position + Vector3.UP * 1.34
		torch.set("base_energy", 2.0)
		root.add_child(torch)
		torch.get_node("Bowl").visible = false
		(torch.get_node("Light") as OmniLight3D).omni_range = 6.0
	# A red pennant above the doorway gives the exit a readable silhouette.
	var cloth := PV.material(Color(0.32, 0.025, 0.045), 0.0, 0.94)
	cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
	var banner := PV.box(root, "GateBanner", Vector3(0.72, 0.62, 0.025), center + Vector3.UP * 3.52, cloth)
	if side > 1:
		banner.rotation.y = PI * 0.5
	var gold := preload("res://materials/m_bronze.tres")
	var emblem := PV.box(banner, "BronzeDiamond", Vector3(0.20, 0.20, 0.038), Vector3.ZERO, gold)
	emblem.rotation.z = PI * 0.25
	var rod_size := Vector3(0.88, 0.04, 0.045) if side < 2 else Vector3(0.045, 0.04, 0.88)
	PV.box(root, "BannerRod", rod_size, center + Vector3.UP * 3.85, gold)

static func gate(parent: Node3D, side: int) -> void:
	var model := GATE.instantiate() as Node3D
	model.position.y = -1.5
	if side > 1:
		model.rotation.y = PI * 0.5
	parent.add_child(model)

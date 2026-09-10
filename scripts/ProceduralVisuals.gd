class_name ProceduralVisuals
extends RefCounted

## Небольшой набор фабрик для процедурных деталей персонажей.
## Все меши создаются один раз при _ready(), а не в игровом цикле.

static func material(color: Color, metallic: float = 0.0,
		roughness: float = 0.65, emission: Color = Color(0, 0, 0, 0),
		emission_energy: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = metallic
	mat.roughness = roughness
	if emission_energy > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
		mat.emission_energy_multiplier = emission_energy
	return mat


static func box(parent: Node, name: String, size: Vector3, pos: Vector3,
		mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)
	return node


static func quad(parent: Node, name: String, size: Vector2, pos: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := QuadMesh.new()
	mesh.size = size
	mesh.material = mat
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)
	return node


static func sphere(parent: Node, name: String, radius: float, pos: Vector3,
		mat: Material, height: float = -1.0) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = height if height > 0.0 else radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 8
	mesh.material = mat
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)
	return node


static func capsule(parent: Node, name: String, radius: float, height: float,
		pos: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	mesh.rings = 4
	mesh.material = mat
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)
	return node


static func cylinder(parent: Node, name: String, radius: float, height: float,
		pos: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.92
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 12
	mesh.rings = 2
	mesh.material = mat
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)
	return node


static func torus(parent: Node, name: String, inner_radius: float,
		outer_radius: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	var mesh := TorusMesh.new()
	mesh.inner_radius = inner_radius
	mesh.outer_radius = outer_radius
	mesh.rings = 16
	mesh.ring_segments = 6
	mesh.material = mat
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)
	return node

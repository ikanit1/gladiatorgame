extends SceneTree

## Rebuild the local game meshes from the Higgsfield art references.
## Run with Godot --headless --path D:/AIfight --script res://tools/build_fortress_assets.gd
const OUT := "res://assets/higgsfield/"
var stone: StandardMaterial3D
var bronze: StandardMaterial3D
var iron: StandardMaterial3D
var ember: StandardMaterial3D

func _initialize() -> void:
	call_deferred("build")

func build() -> void:
	stone = material("Carved limestone", Color(0.58, 0.56, 0.52), 0.0, 0.91)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.11
	noise.fractal_octaves = 4
	var ramp := Gradient.new()
	ramp.colors = PackedColorArray([Color(0.50, 0.48, 0.44), Color(0.94, 0.91, 0.86)])
	var grain := NoiseTexture2D.new()
	grain.width = 512
	grain.height = 512
	grain.seamless = true
	grain.noise = noise
	grain.color_ramp = ramp
	await grain.changed
	stone.albedo_texture = grain
	stone.uv1_scale = Vector3(1.0, 1.0, 1.0)
	bronze = material("Aged bronze", Color(0.43, 0.25, 0.09), 0.72, 0.42)
	iron = material("Forged iron", Color(0.09, 0.105, 0.12), 0.78, 0.47)
	ember = material("Ember", Color(0.65, 0.065, 0.006), 0.0, 0.9)
	ember.emission_enabled = true
	ember.emission = Color(1.0, 0.16, 0.015)
	ember.emission_energy_multiplier = 2.5
	save_model(pillar(), "fortress_pillar")
	save_model(brazier(), "bronze_brazier")
	save_model(gate(), "iron_portcullis")
	quit()

func material(label: String, color: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = label
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rough
	return m

func box(parent: Node3D, label: String, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat
	instance(parent, label, mesh, pos)

func instance(parent: Node3D, label: String, mesh: Mesh, pos := Vector3.ZERO) -> void:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.position = pos
	parent.add_child(node)

## Revolved profile (radius, height); fluting fades smoothly at the ends.
func profile(parent: Node3D, label: String, rings: Array[Vector2], segments: int,
		mat: Material, flutes: int = 0) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(mat)
	var max_y: float = rings[-1].y
	for j in range(rings.size() - 1):
		for i in range(segments):
			var points: Array[Vector3] = []
			var uvs: Array[Vector2] = []
			for corner in [Vector2i(i, j), Vector2i(i + 1, j), Vector2i(i + 1, j + 1), Vector2i(i, j + 1)]:
				var a := float(corner.x) / segments * TAU
				var p := rings[corner.y]
				var fade := sin(clampf((p.y - 0.42) / 2.15, 0.0, 1.0) * PI)
				var r := p.x - (0.027 * (0.5 + 0.5 * cos(a * flutes)) * fade if flutes > 0 else 0.0)
				points.append(Vector3(cos(a) * r, p.y, sin(a) * r))
				uvs.append(Vector2(float(corner.x) / segments, p.y / maxf(max_y, 0.01)))
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_uv(uvs[k])
				st.add_vertex(points[k])
	st.generate_normals()
	st.generate_tangents()
	# append_from() needs indexed geometry when merging with indexed primitives.
	st.index()
	instance(parent, label, st.commit())

func pillar() -> Node3D:
	var root_node := Node3D.new()
	root_node.name = "FortressPillar"
	box(root_node, "Foot", Vector3(0.72, 0.12, 0.72), Vector3(0, 0.06, 0), stone)
	box(root_node, "Plinth", Vector3(0.62, 0.13, 0.62), Vector3(0, 0.185, 0), stone)
	profile(root_node, "FlutedShaft", [Vector2(0, 0.25), Vector2(0.30, 0.25), Vector2(0.31, 0.30), Vector2(0.28, 0.36), Vector2(0.25, 0.42), Vector2(0.245, 0.55), Vector2(0.24, 1.0), Vector2(0.232, 1.6), Vector2(0.225, 2.2), Vector2(0.23, 2.55), Vector2(0.27, 2.62), Vector2(0.30, 2.70), Vector2(0, 2.70)], 64, stone, 12)
	profile(root_node, "Collar", [Vector2(0.23, 2.55), Vector2(0.27, 2.57), Vector2(0.27, 2.61), Vector2(0.23, 2.63)], 32, bronze)
	box(root_node, "Capital", Vector3(0.63, 0.19, 0.63), Vector3(0, 2.79, 0), stone)
	box(root_node, "BronzeCrown", Vector3(0.66, 0.045, 0.66), Vector3(0, 2.905, 0), bronze)
	box(root_node, "Capstone", Vector3(0.70, 0.095, 0.70), Vector3(0, 2.975, 0), stone)
	return root_node

func brazier() -> Node3D:
	var root_node := Node3D.new()
	root_node.name = "BronzeBrazier"
	box(root_node, "Foot", Vector3(0.68, 0.1, 0.68), Vector3(0, 0.05, 0), stone)
	box(root_node, "Step", Vector3(0.57, 0.09, 0.57), Vector3(0, 0.145, 0), stone)
	profile(root_node, "Pedestal", [Vector2(0, 0.19), Vector2(0.35, 0.19), Vector2(0.30, 0.25), Vector2(0.235, 1.12), Vector2(0.31, 1.20), Vector2(0, 1.20)], 4, stone)
	profile(root_node, "OctagonalBowl", [Vector2(0, 1.18), Vector2(0.20, 1.18), Vector2(0.25, 1.23), Vector2(0.36, 1.33), Vector2(0.43, 1.52), Vector2(0.45, 1.58), Vector2(0.45, 1.63), Vector2(0.395, 1.63), Vector2(0.38, 1.53), Vector2(0.28, 1.38), Vector2(0, 1.36)], 16, bronze)
	for i in range(4):
		var a := i * PI * 0.5
		box(root_node, "BowlBrace%d" % i, Vector3(0.07, 0.33, 0.07), Vector3(cos(a) * 0.33, 1.29, sin(a) * 0.33), bronze)
	for i in range(9):
		var coal := SphereMesh.new()
		coal.radius = 0.075
		coal.height = 0.11
		coal.radial_segments = 8
		coal.rings = 3
		coal.material = ember if i % 3 == 0 else iron
		var a := float(i) * 2.4
		var r := 0.07 + 0.018 * i
		instance(root_node, "Coal%d" % i, coal, Vector3(cos(a) * r, 1.44, sin(a) * r))
	return root_node

func gate() -> Node3D:
	var root_node := Node3D.new()
	root_node.name = "IronPortcullis"
	for i in range(9):
		var x := -0.86 + i * 0.215
		box(root_node, "Bar%d" % i, Vector3(0.048, 2.72, 0.08), Vector3(x, 1.5, 0), iron)
		var tip := CylinderMesh.new()
		tip.top_radius = 0.0
		tip.bottom_radius = 0.08
		tip.height = 0.18
		tip.radial_segments = 4
		tip.material = bronze
		instance(root_node, "Spear%d" % i, tip, Vector3(x, 2.90, 0))
	for y in [0.35, 1.05, 2.0, 2.72]:
		box(root_node, "Crossbar", Vector3(1.90, 0.09, 0.12), Vector3(0, y, 0), iron)
		for i in range(9):
			box(root_node, "Rivet", Vector3(0.063, 0.045, 0.15), Vector3(-0.86 + i * 0.215, y, 0), bronze)
	var medallion := CylinderMesh.new()
	medallion.top_radius = 0.19
	medallion.bottom_radius = 0.19
	medallion.height = 0.1
	medallion.radial_segments = 12
	medallion.material = bronze
	instance(root_node, "LockMedallion", medallion, Vector3(0, 1.5, 0))
	(root_node.get_node("LockMedallion") as Node3D).rotation.x = PI * 0.5
	return root_node

func save_model(node: Node3D, filename: String) -> void:
	# Bake each material group into one surface: one draw per material, shared by instances.
	var groups: Dictionary = {}
	for child in node.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		for surface in range(mi.mesh.get_surface_count()):
			var mat := mi.mesh.surface_get_material(surface)
			if not groups.has(mat):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				st.set_material(mat)
				groups[mat] = st
			(groups[mat] as SurfaceTool).append_from(mi.mesh, surface, mi.transform)
	var baked := ArrayMesh.new()
	for mat in groups:
		(groups[mat] as SurfaceTool).commit(baked)
	var clean := Node3D.new()
	clean.name = node.name
	instance(clean, "Mesh", baked)
	clean.get_child(0).owner = clean
	var packed := PackedScene.new()
	assert(packed.pack(clean) == OK)
	assert(ResourceSaver.save(packed, OUT + "models/" + filename + ".tscn") == OK)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	assert(doc.append_from_scene(clean, state) == OK)
	assert(doc.write_to_filesystem(state, OUT + "models/" + filename + ".glb") == OK)
	print("Saved ", filename, " surfaces=", baked.get_surface_count())
	node.free()
	clean.free()

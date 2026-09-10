extends RefCounted
## Shared, sculpted mesh resources; only joint nodes are unique per character.
## Visual construction uses no gameplay RNG and never adds physics bodies.

const PV := preload("res://scripts/ProceduralVisuals.gd")
static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}

static func material(key: String, color: Color, metal := 0.0, rough := 0.8) -> StandardMaterial3D:
	if _materials.has(key):
		return _materials[key]
	var mat := PV.material(color, metal, rough)
	var noise := FastNoiseLite.new()
	noise.seed = 71
	noise.frequency = 0.08
	noise.fractal_octaves = 3
	var texture := NoiseTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.noise = noise
	texture.seamless = true
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.81, 0.79, 0.76))
	ramp.set_color(1, Color(1.0, 0.98, 0.94))
	texture.color_ramp = ramp
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_materials[key] = mat
	return mat

static func joint(parent: Node3D, name: String, pos: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = name
	node.position = pos
	parent.add_child(node)
	return node

static func hide_nodes(parent: Node, paths: Array) -> void:
	for path in paths:
		var node := parent.get_node_or_null(path)
		if node is GeometryInstance3D:
			node.hide()

static func instance(parent: Node3D, name: String, mesh: Mesh, pos: Vector3,
		mat: Material, size := Vector3.ONE) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = name
	node.mesh = mesh
	node.material_override = mat
	node.position = pos
	node.scale = size
	node.set_meta("sculpted", true)
	parent.add_child(node)
	return node

static func ellipsoid(parent: Node3D, name: String, pos: Vector3,
		size: Vector3, mat: Material) -> MeshInstance3D:
	if not _meshes.has("sphere"):
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 20
		sphere.rings = 12
		_meshes["sphere"] = sphere
	return instance(parent, name, _meshes["sphere"], pos, mat, size)

## Elliptical cross sections form tapered muscles, fitted armour and footwear.
static func loft(parent: Node3D, name: String, profile: Array[Vector3],
		pos: Vector3, mat: Material, segments := 20) -> MeshInstance3D:
	var key := str(profile) + str(segments)
	if not _meshes.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for ring in range(profile.size() - 1):
			for side in segments:
				var corners: Array[Vector3] = []
				var uvs: Array[Vector2] = []
				for pair in [Vector2i(ring, side), Vector2i(ring + 1, side),
						Vector2i(ring + 1, side + 1), Vector2i(ring, side + 1)]:
					var section := profile[pair.x]
					var angle := TAU * float(pair.y) / segments
					corners.append(Vector3(cos(angle) * section.y, section.x, sin(angle) * section.z))
					uvs.append(Vector2(float(pair.y) / segments, float(pair.x) / (profile.size() - 1)))
				for index in [0, 2, 1, 0, 3, 2]:
					st.set_uv(uvs[index])
					st.add_vertex(corners[index])
		st.generate_normals()
		st.index()
		_meshes[key] = st.commit()
	return instance(parent, name, _meshes[key], pos, mat)

static func band(parent: Node3D, name: String, y: float, rx: float,
		rz: float, height: float, mat: Material) -> MeshInstance3D:
	return loft(parent, name, [Vector3(-height * 0.5, rx, rz),
		Vector3(height * 0.5, rx, rz)], Vector3(0, y, 0), mat)

static func cloth(parent: Node3D, name: String, width: float, length: float,
		mat: Material, taper := 0.85, torn := false) -> MeshInstance3D:
	var key := "cloth%s_%s_%s_%s" % [width, length, taper, torn]
	if not _meshes.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for row in 5:
			for col in 8:
				for corner in [Vector2i(col, row), Vector2i(col, row + 1), Vector2i(col + 1, row + 1),
						Vector2i(col, row), Vector2i(col + 1, row + 1), Vector2i(col + 1, row)]:
					var u := float(corner.x) / 8.0
					var v := float(corner.y) / 5.0
					var hem := 0.045 * sin(u * 39.0) * v * v if torn else 0.012 * sin(u * PI) * v
					st.set_uv(Vector2(u, v))
					st.add_vertex(Vector3((u - 0.5) * width * lerpf(1.0, taper, v),
						-length * v + hem, sin(u * PI * 6.0) * 0.018 + 0.035 * v * v))
		st.generate_normals()
		st.index()
		_meshes[key] = st.commit()
	return instance(parent, name, _meshes[key], Vector3.ZERO, mat)

static func build_limbs(body: Node3D, undead: bool) -> void:
	var skin := material("undead" if undead else "skin", Color("76816a") if undead else Color("b98b68"))
	var leather := material("leather", Color("433027"))
	var bronze := material("bronze", Color("a8834b"), 0.65, 0.47)
	var bone := material("bone", Color("aba58a"))
	for side in ["L", "R"]:
		var leg: Node3D = body.get_node("Leg" + side)
		hide_nodes(leg, ["Mesh", "Greave"])
		leg.position = Vector3(-0.135 if side == "L" else 0.135, 0.84 if undead else 0.92, 0)
		var thigh_length := 0.38 if undead else 0.43
		var calf_length := 0.34 if undead else 0.37
		var radius := 0.095 if undead else 0.12
		loft(leg, "Thigh", [Vector3(-thigh_length, 0.06, 0.07), Vector3(-thigh_length * 0.8, 0.08, 0.085),
			Vector3(-thigh_length * 0.35, radius, radius * 1.08), Vector3(-0.02, radius * 0.8, radius * 0.9),
			Vector3(0.01, 0.01, 0.01)], Vector3.ZERO, skin)
		var knee := joint(leg, "Knee", Vector3(0, -thigh_length, 0))
		ellipsoid(knee, "Patella", Vector3(0, 0.01, -0.03), Vector3(0.078, 0.08, 0.075), bone if undead else bronze)
		loft(knee, "Calf", [Vector3(-calf_length, 0.043, 0.05), Vector3(-calf_length * 0.65, 0.062, 0.068),
			Vector3(-calf_length * 0.25, radius * 0.8, radius), Vector3(0, 0.057, 0.063)], Vector3.ZERO, skin)
		if not undead:
			loft(knee, "GreavePlate", [Vector3(-0.34, 0.065, 0.069), Vector3(-0.18, 0.088, 0.10),
				Vector3(-0.035, 0.085, 0.105)], Vector3(0, 0, -0.014), bronze)
		for y in [-0.31, -0.26]:
			band(knee, "Binding", y, 0.069, 0.077, 0.025, leather)
		var foot := joint(knee, "Foot", Vector3(0, -calf_length, 0))
		ellipsoid(foot, "FootMesh", Vector3(0, -0.047, -0.075), Vector3(0.081, 0.06, 0.155), skin)
		if not undead:
			ellipsoid(foot, "Sole", Vector3(0, -0.085, -0.065), Vector3(0.085, 0.023, 0.16), leather)
			for z in [-0.03, -0.12]:
				ellipsoid(foot, "SandalStrap", Vector3(0, -0.022, z), Vector3(0.083, 0.027, 0.02), leather)
		else:
			for toe in 4:
				ellipsoid(foot, "Toe", Vector3((toe - 1.5) * 0.033, -0.053, -0.198), Vector3(0.021, 0.032, 0.047), skin)

		var arm: Node3D = body.get_node(("Torso/Arm" if undead else "Arm") + side)
		hide_nodes(arm, ["UpperArm", "Forearm", "Bracer", "Pauldron", "Hand", "ShoulderBoss"])
		var upper_length := 0.30 if undead else 0.33
		loft(arm, "Bicep", [Vector3(-upper_length, 0.051, 0.057), Vector3(-upper_length * 0.55, 0.073, 0.086),
			Vector3(-0.04, 0.089, 0.087), Vector3(0.025, 0.02, 0.02)], Vector3.ZERO, skin)
		ellipsoid(arm, "Deltoid", Vector3(0, -0.025, 0),
			Vector3(0.084, 0.10, 0.083) if undead else Vector3(0.102, 0.12, 0.10), skin)
		if not undead:
			for i in 3:
				var shell := ellipsoid(arm, "ShoulderLamella", Vector3(0, 0.025 - i * 0.042, 0),
					Vector3(0.13 - i * 0.008, 0.046, 0.13 - i * 0.01), bronze)
				shell.rotation_degrees.z = -12 if side == "R" else 12
		var elbow := joint(arm, "Elbow", Vector3(0, -upper_length, 0))
		ellipsoid(elbow, "ElbowJoint", Vector3.ZERO, Vector3(0.056, 0.058, 0.057), skin)
		loft(elbow, "ForearmMesh", [Vector3(-0.29, 0.037, 0.039), Vector3(-0.20, 0.044, 0.05),
			Vector3(-0.08, 0.066, 0.068), Vector3(0, 0.051, 0.055)], Vector3.ZERO, skin)
		for i in (2 if undead else 4):
			band(elbow, "WristWrap", -0.22 + i * 0.035, 0.054 + i * 0.004, 0.057 + i * 0.004, 0.025, leather)
		if not undead:
			ellipsoid(elbow, "BracerPlate", Vector3(0, -0.145, -0.042), Vector3(0.068, 0.105, 0.035), bronze)
		var hand := joint(elbow, "Wrist", Vector3(0, -0.29, 0))
		ellipsoid(hand, "Palm", Vector3(0, -0.045, 0), Vector3(0.058, 0.07, 0.033), skin)
		for finger in 4:
			var digit := ellipsoid(hand, "Finger", Vector3((finger - 1.5) * 0.025, -0.105, -0.008),
				Vector3(0.015, 0.061 if undead else 0.038, 0.019), skin)
			digit.rotation_degrees.x = 22 if undead else 62
		ellipsoid(hand, "Thumb", Vector3(-0.054 if side == "R" else 0.054, -0.045, -0.018),
			Vector3(0.021, 0.041, 0.024), skin)

static func gladiator(visual: Node3D) -> void:
	var body: Node3D = visual.get_node("Body")
	var torso: MeshInstance3D = body.get_node("Torso")
	var bronze := material("bronze", Color("a8834b"), 0.65, 0.47)
	var trim := material("trim", Color("c8a768"), 0.7, 0.4)
	var leather := material("leather", Color("433027"))
	var cloth_mat := material("crimson", Color("642731"), 0.0, 0.94)
	cloth_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	build_limbs(body, false)
	# Retain the torso node and its animation binding, replace the inverted cone.
	var shell := loft(body, "CuirassSource", [Vector3(-0.22, 0.205, 0.135), Vector3(-0.14, 0.195, 0.13),
		Vector3(0.015, 0.258, 0.168), Vector3(0.14, 0.275, 0.155), Vector3(0.205, 0.205, 0.115)],
		Vector3.ZERO, bronze)
	torso.mesh = shell.mesh
	torso.material_override = bronze
	shell.free()
	for side in [-1.0, 1.0]:
		var pec := ellipsoid(torso, "Pectoral", Vector3(side * 0.123, 0.075, -0.134), Vector3(0.128, 0.075, 0.040), bronze)
		pec.rotation_degrees.z = side * 8.0
		for row in 3:
			ellipsoid(torso, "AbdominalPlate", Vector3(side * 0.067, -0.055 - row * 0.064, -0.125),
				Vector3(0.069 - row * 0.006, 0.038, 0.041), bronze)
	band(torso, "CuirassHem", -0.207, 0.209, 0.143, 0.025, trim)
	band(torso, "Collar", 0.201, 0.208, 0.12, 0.022, trim)
	hide_nodes(body, ["Belt", "Skirt"])
	band(body, "WarBelt", 1.07, 0.247, 0.166, 0.095, leather)
	ellipsoid(body, "Buckle", Vector3(0, 1.07, -0.177), Vector3(0.075, 0.05, 0.016), trim)
	for i in 12:
		var angle := TAU * float(i) / 12.0
		var root := joint(body, "Pteruges%d" % i, Vector3(sin(angle) * 0.244, 1.02, -cos(angle) * 0.164))
		root.rotation.y = -angle
		root.rotation.x = deg_to_rad(9)
		cloth(root, "LeatherStrip", 0.12, 0.34 + 0.025 * cos(angle * 2), leather, 0.77)
		ellipsoid(root, "BronzeTip", Vector3(0, -0.315, 0.015), Vector3(0.042, 0.035, 0.012), bronze)
	var skirt := loft(body, "Underskirt", [Vector3(0.70, 0.295, 0.20), Vector3(1.04, 0.23, 0.16)], Vector3.ZERO, cloth_mat)
	skirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_DOUBLE_SIDED
	# A narrow diamond section and tapered point replace the rectangular blade.
	var blade: MeshInstance3D = body.get_node("ArmR/Sword/Blade")
	var blade_source := loft(body, "BladeSource", [Vector3(-0.28, 0.026, 0.012), Vector3(-0.23, 0.039, 0.013),
		Vector3(0.18, 0.029, 0.010), Vector3(0.32, 0.0, 0.0)], Vector3.ZERO,
		material("steel", Color("abb8bd"), 0.75, 0.3), 4)
	blade.mesh = blade_source.mesh
	blade.material_override = blade_source.material_override
	blade_source.free()
	body.get_node("Head/Skull").material_override = material("face_shadow", Color("69513d"))
	var shield: Node3D = body.get_node("ArmL/Shield")
	shield.get_node("ShieldModel").hide()
	# Shield pivot retains the established arm compensation; the new face lies
	# in its local XZ plane, with the outward surface pointing down local Y.
	var board := PV.cylinder(shield, "ShieldFace", 0.36, 0.048, Vector3.ZERO, bronze)
	board.mesh.radial_segments = 48
	PV.torus(shield, "ShieldRim", 0.337, 0.367, Vector3(0, -0.026, 0), trim)
	PV.torus(shield, "InnerRim", 0.266, 0.273, Vector3(0, -0.03, 0), trim)
	ellipsoid(shield, "ShieldBoss", Vector3(0, -0.035, 0), Vector3(0.105, 0.07, 0.105), trim)
	for i in 12:
		var angle := TAU * i / 12.0
		ellipsoid(shield, "Rivet", Vector3(cos(angle) * 0.317, -0.029, sin(angle) * 0.317),
			Vector3(0.013, 0.009, 0.013), trim)
	# Give the existing imported helmet the same aged finish as the cuirass.
	for mesh in body.get_node("Head/HelmetModel").find_children("*", "MeshInstance3D", true, false):
		for surface in mesh.mesh.get_surface_count():
			var source: Material = mesh.get_active_material(surface)
			if source is StandardMaterial3D:
				var mat: StandardMaterial3D = source.duplicate()
				mat.metallic = minf(mat.metallic, 0.6)
				mat.roughness = maxf(mat.roughness, 0.48)
				mesh.set_surface_override_material(surface, mat)
	consolidate(body, "gladiator")

static func zombie(visual: Node3D) -> void:
	var body: Node3D = visual.get_node("Body")
	var torso: Node3D = body.get_node("Torso")
	var head: Node3D = torso.get_node("Head")
	var skin := material("undead", Color("76816a"))
	var bone := material("bone", Color("aba58a"))
	var dark := material("cavities", Color("262821"))
	var leather := material("leather", Color("433027"))
	var rag := material("rags", Color("514a3b"))
	rag.cull_mode = BaseMaterial3D.CULL_DISABLED
	build_limbs(body, true)
	hide_nodes(body, ["Rags", "Torso/Mesh", "Torso/Head/Skull"])
	loft(torso, "Ribcage", [Vector3(-0.22, 0.145, 0.10), Vector3(-0.1, 0.15, 0.105),
		Vector3(0.06, 0.215, 0.13), Vector3(0.24, 0.235, 0.135), Vector3(0.30, 0.16, 0.09)], Vector3.ZERO, skin)
	loft(head, "SkullSculpt", [Vector3(-0.125, 0.056, 0.061), Vector3(-0.06, 0.091, 0.081),
		Vector3(0.02, 0.127, 0.10), Vector3(0.12, 0.117, 0.10), Vector3(0.17, 0.062, 0.063),
		Vector3(0.183, 0.002, 0.002)], Vector3.ZERO, skin)
	for side in [-1.0, 1.0]:
		ellipsoid(head, "EyeSocket", Vector3(side * 0.062, 0.025, -0.088), Vector3(0.043, 0.032, 0.021), dark)
		var brow := ellipsoid(head, "Brow", Vector3(side * 0.063, 0.057, -0.088), Vector3(0.054, 0.019, 0.028), bone)
		brow.rotation.z = side * 0.18
		ellipsoid(head, "Cheekbone", Vector3(side * 0.082, -0.038, -0.069), Vector3(0.042, 0.035, 0.038), bone)
		ellipsoid(head, "Ear", Vector3(side * 0.125, 0.004, -0.002), Vector3(0.024, 0.044, 0.021), skin)
		for i in 4:
			var rib := ellipsoid(torso, "Rib", Vector3(side * (0.085 + i * 0.009), 0.025 + i * 0.047, -0.115),
				Vector3(0.088, 0.018, 0.029), bone)
			rib.rotation.z = side * -0.24
		ellipsoid(torso, "Clavicle", Vector3(side * 0.115, 0.245, -0.092), Vector3(0.115, 0.022, 0.034), bone)
	ellipsoid(head, "Nose", Vector3(0, -0.018, -0.105), Vector3(0.027, 0.044, 0.035), bone)
	var jaw: MeshInstance3D = head.get_node("Jaw")
	jaw.mesh = null
	jaw.position = Vector3(0, -0.07, -0.015)
	ellipsoid(jaw, "Mandible", Vector3(0, -0.041, -0.045), Vector3(0.082, 0.04, 0.052), skin)
	ellipsoid(jaw, "Mouth", Vector3(0, -0.01, -0.07), Vector3(0.069, 0.018, 0.019), dark)
	for i in 6:
		ellipsoid(jaw, "Tooth", Vector3((i - 2.5) * 0.019, -0.005, -0.085), Vector3(0.007, 0.013, 0.009), bone)
	band(body, "RopeBelt", 0.85, 0.21, 0.15, 0.06, leather)
	for i in 9:
		var angle := TAU * i / 9.0
		var root := joint(body, "Rag%d" % i, Vector3(sin(angle) * 0.20, 0.82, -cos(angle) * 0.142))
		root.rotation.y = -angle
		cloth(root, "TornLinen", 0.155, 0.24 + 0.06 * sin(i * 2.7), rag, 0.73, true)
	consolidate(body, "zombie")

## Batch rigid details by joint and material; joints themselves remain movable.
static func consolidate(root: Node3D, prefix: String, current: Node3D = null) -> void:
	if current == null:
		current = root
	var groups: Dictionary = {}
	for child in current.get_children():
		if child is Node3D:
			consolidate(root, prefix, child)
		if child is MeshInstance3D and child.has_meta("sculpted") and child.get_child_count() == 0:
			var mat: Material = child.material_override
			if not groups.has(mat):
				groups[mat] = []
			groups[mat].append(child)
	for mat: Material in groups:
		var nodes: Array = groups[mat]
		if nodes.size() < 2:
			continue
		var cache_key := "%s/%s/%s" % [prefix, root.get_path_to(current), mat.get_instance_id()]
		if not _meshes.has(cache_key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			for node: MeshInstance3D in nodes:
				st.append_from(node.mesh, 0, node.transform)
			_meshes[cache_key] = st.commit()
		instance(current, "SculptedDetails", _meshes[cache_key], Vector3.ZERO, mat)
		for node: MeshInstance3D in nodes:
			node.free()

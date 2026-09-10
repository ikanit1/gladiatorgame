extends SceneTree

var failures: Array[String] = []
var checks := 0

func verify(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var g: Gladiator = load("res://scenes/Gladiator.tscn").instantiate()
	# This fixture exercises visuals without activating player or learning input.
	g.get_node("PlayerInput").free()
	g.get_node("Brain").free()
	root.add_child(g)
	g.set_physics_process(false)
	var v: Node3D = g.get_node("Visuals")
	v.set_process(false)
	var z: Zombie = load("res://scenes/Zombie.tscn").instantiate()
	root.add_child(z)
	z.set_physics_process(false)
	z.health = z.max_health
	var zv: Node3D = z.get_node("Visuals")
	zv.set_process(false)
	var g_collision: Transform3D = g.get_node("Collision").transform
	var z_collision: Transform3D = z.get_node("Collision").transform
	for fps in [30, 60, 144]:
		var delta: float = 1.0 / fps
		for direction in [Vector3.FORWARD, Vector3.BACK, Vector3.LEFT, Vector3.RIGHT]:
			v._on_respawned()
			g.velocity = direction * 3.0
			var lowest_foot := 100.0
			var highest_foot := -100.0
			var swing_travel := 0.0
			var stance_travel := 0.0
			var left_foot: Node3D = v.get_node("Body/LegL/Knee/Foot")
			for frame in fps * 2:
				var previous_position := left_foot.global_position
				var previous_phase: float = v._walk_phase
				v._process(delta)
				# Check the actual foot trajectory, not just its height: the
				# lifted foot advances; the planted foot travels back under the body.
				if frame > fps:
					var travel: float = (left_foot.global_position - previous_position).dot(direction)
					if previous_phase > 0.2 and v._walk_phase < PI - 0.2 and v._walk_phase > previous_phase:
						swing_travel += travel
					if previous_phase > PI + 0.2 and v._walk_phase < TAU - 0.2 and v._walk_phase > previous_phase:
						stance_travel += travel
				for side in ["L", "R"]:
					var foot: Node3D = v.get_node("Body/Leg%s/Knee/Foot" % side)
					lowest_foot = minf(lowest_foot, foot.global_position.y)
					highest_foot = maxf(highest_foot, foot.global_position.y)
			verify(lowest_foot >= 0.09, "feet below floor at %d fps: %f" % [fps, lowest_foot])
			verify(highest_foot - lowest_foot > 0.04, "no foot lift at %d fps" % fps)
			verify(swing_travel > 0.05, "lifted foot moves against travel direction at %d fps" % fps)
			verify(stance_travel < -0.05, "planted foot moves with body at %d fps" % fps)
			g.velocity = Vector3.ZERO
			for frame in fps:
				v._process(delta)
			verify(v._move_amount < 0.005, "locomotion fails to settle")
			verify(absf(v.get_node("Body").position.y) < 0.001, "idle keeps bobbing")
		v._on_respawned()
		g.is_blocking = true
		for frame in fps:
			v._process(delta)
		var body: Node3D = v.get_node("Body")
		var shield: Node3D = v.get_node("Body/ArmL/Shield")
		var face := (body.global_basis.inverse() * shield.global_basis).orthonormalized()
		verify((-face.y).dot(Vector3.FORWARD) > 0.999, "shield face turns away during block")
		verify(shield.global_position.y > 1.1, "shield fails to cover chest")
		var hand_position: Vector3 = v._elbow_l.global_transform * Vector3(0, -0.335, -0.025)
		verify(shield.to_local(hand_position).y > 0.10, "hand protrudes through shield face")
		for yaw in [-0.8, 0.0, 0.8]:
			for pitch in [-0.3, 0.0, 0.3]:
				g.intent_aim_direction = Vector3.FORWARD.rotated(Vector3.RIGHT, pitch).rotated(Vector3.UP, yaw)
				g.velocity = Vector3.RIGHT * 2.0
				for frame in fps:
					v._process(delta)
				var facing := -shield.global_basis.y.normalized()
				verify(facing.dot(g.intent_aim_direction) > 0.98, "shield fails to track aim while strafing")
				var wrist: Vector3 = v._elbow_l.global_transform * Vector3(0, -0.335, -0.025)
				verify(shield.to_local(wrist).y > 0.10, "IK pushes fingers through shield")
				verify(v._elbow_l.global_position.distance_to(v._arm_l.global_position) < 0.331, "IK stretches upper arm")
		g.intent_aim_direction = Vector3.ZERO
		g.velocity = Vector3.ZERO
		g.is_blocking = false
		for frame in fps:
			v._process(delta)
		var contact_tips: Array[Vector3] = []
		for attack in [Gladiator.AttackType.SWORD, Gladiator.AttackType.SWORD,
				Gladiator.AttackType.SWORD, Gladiator.AttackType.SWORD, Gladiator.AttackType.KICK]:
			g._begin_attack(attack)
			g._tick_combat(g.sword_windup if attack == Gladiator.AttackType.SWORD else g.kick_windup)
			v._process(0.0)
			if attack == Gladiator.AttackType.SWORD:
				verify(v._sword_swing == contact_tips.size(), "sword sequence skips a variant")
				var tip: Vector3 = v._blade.global_transform * Vector3(0, 0.32, 0)
				for previous_tip in contact_tips:
					verify(tip.distance_to(previous_tip) > 0.10, "sword variants have indistinguishable contact poses")
				contact_tips.append(tip)
			v._process(delta)
			if attack == Gladiator.AttackType.KICK:
				verify(v.get_node("Body/LegR/Knee/Foot").global_position.z < -0.4, "kick points backwards")
			for frame in fps:
				g._tick_combat(delta)
				v._process(delta)
				if attack == Gladiator.AttackType.SWORD and v._attack_t >= 0:
					for point in [Vector3(0, -0.28, 0), Vector3.ZERO, Vector3(0, 0.32, 0)]:
						var local_point: Vector3 = shield.to_local(v._blade.global_transform * point)
						verify(Vector2(local_point.x, local_point.z).length() > 0.37 or absf(local_point.y) > 0.085,
							"sword intersects shield at %d fps" % fps)
			verify(v._attack_t < 0 and v._kick_t < 0, "attack animation fails to complete")
			verify(not v._slash_trail.visible, "trail remains after attack")
			verify(v._arm_r.rotation_degrees.distance_to(v.REST_ARM_R) < 0.01, "sword arm retains attack pose")
			verify(v._wrist_degrees.distance_to(v.REST_SWORD) < 0.01, "sword wrist retains attack pose")
		g._begin_attack(Gladiator.AttackType.SWORD)
		verify(v._sword_swing == v.SwordSwing.DIAGONAL, "sword sequence fails to wrap")
		g._alive = false
		g._cancel_attack()
		for frame in fps:
			v._process(delta)
		verify(not v._slash_trail.visible, "trail remains on corpse")
		g._alive = true
		g.revived.emit(45)
		v._process(delta)
		verify(v._death_t == 0 and v._attack_t < 0 and v._kick_t < 0, "revive retains transient state")
		verify(v._pivot.rotation.length() < 0.001, "revive retains death rotation")
		# Actual AnimationPlayer events drive all three attack phases.
		for variant in [Zombie.Variant.NORMAL, Zombie.Variant.RUNNER, Zombie.Variant.BRUTE]:
			z.variant = variant
			z.state = Zombie.State.IDLE
			z.velocity = Vector3.ZERO
			z.respawned.emit()
			for frame in fps:
				zv._process(delta)
			verify(zv._brute_growth.visible == (variant == Zombie.Variant.BRUTE), "variant retains wrong geometry")
			var previous: Vector3 = zv._arm_r.rotation_degrees
			var max_jump := 0.0
			z._active = true
			z._begin_attack()
			for frame in int(ceil(z.combat_animation.duration * fps)) + 2:
				z.combat_animation.step(delta, 1)
				zv._process(delta)
				max_jump = maxf(max_jump, previous.distance_to(zv._arm_r.rotation_degrees))
				previous = zv._arm_r.rotation_degrees
			verify(max_jump < 40, "zombie attack snaps at %d fps: %f degrees" % [fps, max_jump])
			z.state = Zombie.State.DEAD
			for frame in fps:
				zv._process(delta)
			z.state = Zombie.State.CHASE
			z.respawned.emit()
			verify(zv._death_t == 0 and zv._flash == 0, "pooled zombie retains death/flash")
			verify(zv._pivot.position == Vector3.ZERO and zv._pivot.rotation == Vector3.ZERO, "pooled zombie retains corpse transform")
	verify(g.get_node("Collision").transform == g_collision, "gladiator collision changed")
	verify(z.get_node("Collision").transform == z_collision, "zombie collision changed")
	verify(g.health == g.max_health and z.health == z.max_health, "visual animation changed health")
	print("CHARACTER_ANIMATION: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures:
		push_error(failure)
	g.free()
	z.free()
	quit(0 if failures.is_empty() else 1)

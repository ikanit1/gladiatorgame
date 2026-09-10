extends SceneTree

const DT := 1.0 / 60.0
var fighter: Gladiator
var controller: Node
var rig: SpringArm3D
var failures := 0
var checks := 0
var attacks: Array[int] = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func release_keys() -> void:
	for action in ["g_forward", "g_back", "g_left", "g_right", "g_block", "g_sword", "g_kick"]:
		Input.action_release(action)

func reset_player(yaw: float = 0.0) -> void:
	release_keys()
	fighter.reset_state(Transform3D(Basis(Vector3.UP, yaw), Vector3.ZERO))
	rig.set("_yaw", 0.0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	attacks.clear()

func step(count: int = 1) -> void:
	for i in range(count):
		await physics_frame
		controller._physics_process(DT)
		fighter._physics_process(DT)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Run without --headless: these input tests require actual mouse capture.")
		quit(2)
		return
	fighter = Gladiator.new()
	fighter.collision_layer = 2
	fighter.collision_mask = 1
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.6
	var collider := CollisionShape3D.new()
	collider.shape = capsule
	collider.position.y = 0.8
	fighter.add_child(collider)
	fighter.set_physics_process(false)
	controller = load("res://scripts/PlayerInput.gd").new()
	controller.name = "PlayerInput"
	fighter.add_child(controller)
	root.add_child(fighter)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(1000, 1, 1000)
	floor_shape.shape = floor_box
	floor_shape.position.y = -0.5
	floor_body.add_child(floor_shape)
	root.add_child(floor_body)
	controller.set_physics_process(false)
	fighter.attack_started.connect(func(kind: int): attacks.append(kind))
	rig = load("res://scripts/ThirdPersonCamera.gd").new()
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	rig.add_child(camera)
	root.add_child(rig)
	rig.set_target(fighter)
	rig.set_process(false)
	camera.current = true
	await physics_frame

	for direction in ["g_forward", "g_back", "g_left", "g_right"]:
		reset_player()
		Input.action_press(direction)
		await step()
		var expected: Vector3 = {"g_forward": Vector3.FORWARD, "g_back": Vector3.BACK, "g_left": Vector3.LEFT, "g_right": Vector3.RIGHT}[direction]
		var planar := Vector3(fighter.velocity.x, 0, fighter.velocity.z)
		check(planar.normalized().dot(expected) > 0.999, direction + " moves in requested direction on first tick")
		await step(12)
		check(fighter.forward().dot(expected) > 0.999, direction + " facing catches up")

	reset_player()
	rig.set("_yaw", PI * 0.5)
	Input.action_press("g_forward")
	await step(10)
	check(fighter.velocity.x < -4.99 and absf(fighter.velocity.z) < 0.001, "W follows rotated camera")
	reset_player()
	Input.action_press("g_forward")
	Input.action_press("g_right")
	await step(10)
	check(absf(Vector2(fighter.velocity.x, fighter.velocity.z).length() - 5.0) < 0.001, "Diagonal speed is capped")
	release_keys()
	await step(5)
	check(Vector2(fighter.velocity.x, fighter.velocity.z).length() < 0.001, "Stops within 84 ms")

	reset_player()
	Input.action_press("g_forward")
	await step(10)
	Input.action_release("g_forward")
	Input.action_press("g_back")
	await step(5)
	check(fighter.velocity.z > 0.0, "Reversal changes travel direction within 84 ms")

	reset_player()
	Input.action_press("g_block")
	Input.action_press("g_left")
	await step(10)
	check(fighter.is_blocking and fighter.velocity.x < -3.2 and fighter.forward().dot(Vector3.FORWARD) > 0.999, "Shield allows lateral steps while facing aim")
	reset_player()
	Input.action_press("g_block")
	Input.action_press("g_back")
	await step(10)
	check(fighter.velocity.z > 1.9 and fighter.velocity.z < 2.0 and fighter.forward().z < -0.99, "Shield retreat preserves facing and speed penalty")

	reset_player()
	fighter.sword_cd = 0.12
	controller.queue_attack(Gladiator.AttackType.SWORD)
	await step(25)
	check(attacks.size() == 1, "Early attack executes exactly once when cooldown ends")
	reset_player()
	fighter.sword_cd = 0.6
	controller.queue_attack(Gladiator.AttackType.SWORD)
	await step(45)
	check(attacks.is_empty(), "Expired input never causes a delayed attack")
	reset_player(PI)
	controller.queue_attack(Gladiator.AttackType.SWORD)
	await step(15)
	check(attacks.size() == 1 and fighter.forward().z < -0.99, "Turnaround attack faces camera aim")
	reset_player()
	controller.queue_attack(Gladiator.AttackType.SWORD)
	controller.queue_attack(Gladiator.AttackType.KICK)
	await step(25)
	check(attacks == [Gladiator.AttackType.KICK], "Latest press replaces pending attack")

	reset_player()
	fighter.stun_time = 0.7
	Input.action_press("g_forward")
	controller.queue_attack(Gladiator.AttackType.SWORD)
	await step(20)
	check(attacks.is_empty() and fighter.velocity.x == 0.0 and fighter.velocity.z == 0.0, "Stun still prevents movement and attacks")
	reset_player()
	fighter.sword_cd = 0.1
	controller.queue_attack(Gladiator.AttackType.SWORD)
	paused = true
	check(controller.get("_queued_attack") == -1, "Pause clears pending input")
	paused = false
	await step(15)
	check(attacks.is_empty(), "Resume does not attack")
	controller.queue_attack(Gladiator.AttackType.SWORD)
	fighter.reset_state(Transform3D.IDENTITY)
	check(controller.get("_queued_attack") == -1, "Respawn clears pending input")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.action_press("g_forward")
	await step()
	check(fighter.intent_move_world == Vector3.ZERO and not fighter.human_movement, "Uncaptured cursor suppresses gameplay input")

	reset_player()
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	check(mouse.is_action_pressed("g_sword"), "Left mouse binds sword")
	controller._unhandled_input(mouse)
	await step()
	check(attacks.size() == 1, "Mouse press reaches attack")
	mouse.button_index = MOUSE_BUTTON_RIGHT
	check(mouse.is_action_pressed("g_block"), "Right mouse binds shield")
	var motion := InputEventMouseMotion.new()
	motion.screen_relative = Vector2(100, 0)
	motion.relative = Vector2(800, 0)
	var body_yaw := fighter.rotation.y
	rig._unhandled_input(motion)
	controller._unhandled_input(motion)
	check(absf(rig.get_yaw() + 0.22) < 0.00001 and fighter.rotation.y == body_yaw, "Mouse moves only camera using unscaled screen input")
	fighter.position = Vector3(100, 0, 0)
	rig._process(DT)
	check(rig.global_position.distance_to(fighter.position + Vector3.UP * rig.height) < 0.001, "Camera snaps to teleport instead of flying across room")

	reset_player()
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(20, 3, 0.5)
	wall_shape.shape = wall_box
	wall_shape.position = Vector3(0, 1.5, -2.0)
	wall.add_child(wall_shape)
	root.add_child(wall)
	Input.action_press("g_forward")
	Input.action_press("g_right")
	await step(65)
	check(fighter.position.z > -1.46 and fighter.position.x > 3.0, "Diagonal input slides along a wall without penetrating it")
	wall.free()
	controller.clear_input()

	var rates_ok := true
	for rate in [30, 60, 120]:
		reset_player(PI)
		fighter.human_movement = true
		fighter.intent_move_world = Vector3.FORWARD
		fighter.intent_facing_yaw = 0.0
		for frame in range(rate / 5):
			fighter._physics_process(1.0 / float(rate))
		if fighter.forward().z > -0.999 or absf(fighter.velocity.z + 5.0) > 0.001:
			rates_ok = false
	check(rates_ok, "Facing and acceleration remain consistent at 30/60/120 Hz")

	await compare_legacy_ai()
	release_keys()
	fighter.free()
	rig.free()
	floor_body.free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	print("CONTROLS: ", checks, " checks, ", failures, " failures")
	quit(0 if failures == 0 else 1)

func compare_legacy_ai() -> void:
	# Compare the old mechanic itself, not a second copy of the new formula.
	var script := GDScript.new()
	script.source_code = FileAccess.get_file_as_string("res://tools/backups/controls_20260910/Gladiator.gd.txt").replace("class_name Gladiator\n", "")
	check(script.reload() == OK, "Legacy baseline compiles")
	var old: CharacterBody3D = script.new()
	var current := Gladiator.new()
	root.add_child(old)
	root.add_child(current)
	old.set_physics_process(false)
	current.set_physics_process(false)
	var equivalent := true
	for i in range(100):
		await physics_frame
		for body in [old, current]:
			body.intent_move = 1.0 if i < 40 else -0.7
			body.intent_turn = 0.5 if i < 65 else -1.0
			body.intent_block = i >= 40 and i < 65
			# Combat timings now intentionally differ; compare locomotion/guard.
			body.intent_sword = false
			body._physics_process(DT)
		if old.velocity.distance_to(current.velocity) > 0.0001 or absf(old.rotation.y - current.rotation.y) > 0.0001:
			equivalent = false
	check(equivalent and not current.human_movement, "100-step AI movement/block trace matches original mechanic")
	old.free()
	current.free()

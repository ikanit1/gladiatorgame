extends SceneTree

var checks := 0
var failures: Array[String] = []
var contacts := 0
var misses := 0
var parries := 0
var g: Gladiator
var enemies: Array[Zombie] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)

func _initialize() -> void:
	call_deferred("run")

func reset_fight() -> void:
	g.reset_state(Transform3D.IDENTITY)
	g.set_physics_process(false)
	g.attack_playback_speed = 1
	for i in enemies.size():
		var z := enemies[i]
		z.set_variant(Zombie.Variant.NORMAL)
		z.activate(Transform3D(Basis(Vector3.UP, PI), Vector3((i - 1.5) * 0.30, 0, -1.5)), g)
		z.set_physics_process(false)
	contacts = 0
	misses = 0
	parries = 0

func run() -> void:
	g = load("res://scenes/Gladiator.tscn").instantiate()
	g.get_node("Brain").free()
	g.get_node("PlayerInput").free()
	root.add_child(g)
	g.set_physics_process(false)
	g.get_node("Visuals").process_mode = Node.PROCESS_MODE_DISABLED
	g.attack_contact.connect(func(_type: int): contacts += 1)
	g.attack_missed.connect(func(_type: int): misses += 1)
	g.successful_parry.connect(func(_source: Node3D): parries += 1)
	for i in 4:
		var z: Zombie = load("res://scenes/Zombie.tscn").instantiate()
		root.add_child(z)
		z.set_physics_process(false)
		z.get_node("Visuals").process_mode = Node.PROCESS_MODE_DISABLED
		enemies.append(z)
	for fps in [30, 60, 144]:
		for speed in [0.5, 1.0, 2.0, 4.0]:
			reset_fight()
			await physics_frame
			await physics_frame
			g.attack_playback_speed = speed
			g.intent_sword = true
			g._handle_attacks()
			check(g.combat_state == Gladiator.CombatState.WINDUP and contacts == 0, "sword must start with a harmless windup")
			var time := 0.0
			while time < 0.9 / speed:
				time += 1.0 / fps
				g._tick_combat(1.0 / fps)
				if time < g.sword_windup / speed - 0.00001:
					check(contacts == 0, "damage event fired before windup completed")
				if g.combat_state != Gladiator.CombatState.IDLE:
					var previous := g.current_attack
					g.intent_kick = true
					g._handle_attacks()
					check(g.current_attack == previous, "button spam interrupted committed attack")
			check(contacts == 1, "animation contact must fire exactly once at %d fps / %s speed" % [fps, speed])
			var hit_count := 0
			for z in enemies:
				if z.health < z.max_health:
					hit_count += 1
					check(is_equal_approx(z.health, z.max_health - g.sword_damage), "target damaged twice in active window")
			check(hit_count == 3, "sword max targets must apply to entire swing")
			check(g.combat_state == Gladiator.CombatState.IDLE and not g._hitbox_enabled, "animation never exits recovery")
	reset_fight()
	g._begin_attack(Gladiator.AttackType.SWORD)
	g.take_damage(1, Vector3.FORWARD)
	g._tick_combat(1.0)
	check(contacts == 0 and g.combat_state == Gladiator.CombatState.STAGGER, "hit in windup must cancel queued animation events")
	reset_fight()
	await physics_frame
	g._begin_attack(Gladiator.AttackType.SWORD)
	g._tick_combat(0.24)
	g.take_damage(1, Vector3.FORWARD)
	check(g.combat_state == Gladiator.CombatState.ACTIVE_HIT, "light hit incorrectly cancels ActiveHit")
	g._enter_downed()
	g._tick_combat(1.0)
	check(not g._hitbox_enabled and not g.combat_animation.running, "downed retains live hitbox")
	g.revive()
	check(g.combat_state == Gladiator.CombatState.IDLE, "revive retains combat state")
	reset_fight()
	g._begin_attack(Gladiator.AttackType.KICK)
	g._tick_combat(0.8)
	check(contacts == 1 and g.combat_state == Gladiator.CombatState.IDLE, "large step skipped method-track events")
	reset_fight()
	g._begin_attack(Gladiator.AttackType.SWORD)
	g._tick_combat(0.1)
	g.attack_playback_speed = 2.0
	g._tick_combat(0.061)
	check(contacts == 1, "mid-swing speed change desynchronises event cursor")
	reset_fight()
	for z in enemies:
		z.deactivate()
	await physics_frame
	await physics_frame
	g._begin_attack(Gladiator.AttackType.SWORD)
	g._tick_combat(1.0)
	check(misses == 1, "empty swing must report one miss only after active window")
	for variant in [Zombie.Variant.NORMAL, Zombie.Variant.RUNNER, Zombie.Variant.BRUTE]:
		reset_fight()
		var z := enemies[0]
		z.set_variant(variant)
		z._begin_attack()
		check(z.attack_windup >= 0.3 and z.attack_windup <= 0.5, "enemy telegraph outside requested window")
		g.intent_block = true
		g._update_block(0.016)
		z.combat_animation.step(z.attack_windup + 0.001, z.effective_attack_speed())
		check(parries == 1 and z.state == Zombie.State.STAGGER and g.health == g.max_health, "timely guard failed to parry variant %d" % variant)
		z.combat_animation.step(2.0, 1.0)
		check(z.state == Zombie.State.STAGGER and not z._hitbox_enabled, "parry overwritten by queued recovery event")
	reset_fight()
	g.intent_block = true
	g._update_block(0.01)
	var z := enemies[0]
	z._begin_attack()
	z.combat_animation.step(z.attack_windup + 0.01, 1)
	check(parries == 0 and g.health == g.max_health and z.state == Zombie.State.ACTIVE_HIT, "held shield must block without auto-parrying")
	reset_fight()
	z = enemies[0]
	z._begin_attack()
	g.intent_block = true
	g._update_block(0.01)
	g._tick_timers(0.51)
	z.combat_animation.step(z.attack_windup + 0.01, 1)
	check(parries == 0 and g.health == g.max_health, "expired parry window should fall back to normal block")
	g.block_stamina = 0.01
	g._update_block(0.1)
	check(g.combat_state == Gladiator.CombatState.STAGGER and not g.is_blocking, "exhausted guard must break")
	reset_fight()
	z = enemies[0]
	z._begin_attack()
	z.take_damage(1, g.position)
	z.combat_animation.step(1, 1)
	check(z.state == Zombie.State.STAGGER and g.health == g.max_health, "enemy hit in windup still attacks")
	reset_fight()
	z = enemies[0]
	z.rotation.y = 0
	z._begin_attack()
	z.combat_animation.step(1.2, 1)
	check(g.health == g.max_health, "enemy can hit behind itself")
	reset_fight()
	z = enemies[0]
	z._begin_attack()
	g._die()
	z._physics_process(0.01)
	check(not z.combat_animation.running and not z._hitbox_enabled, "invalid target leaves pending hit events")
	print("COMBAT_ANIMATION: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures:
		push_error(failure)
	g.free()
	for enemy in enemies:
		enemy.free()
	quit(0 if failures.is_empty() else 1)

extends SceneTree

var checks := 0
var failures: Array[String] = []

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var arena: Arena = load("res://scenes/Arena.tscn").instantiate()
	arena.pool_size = 3
	arena.potion_pool_size = 0
	arena.human_control = false
	root.add_child(arena)
	arena.set_physics_process(false)
	arena.gladiator.set_physics_process(false)
	await process_frame
	await process_frame
	var fx: CombatFX = arena.get_node("CombatFX")
	fx.set_process(false)
	check(fx._pools.size() == 6 and fx._bursts.size() == fx.pool_per_effect, "visible arena creates bounded FX pools")
	arena.get_node("Decor").hide()
	check(fx.is_visible_in_tree(), "dungeon decor visibility hides combat effects")
	var z: Zombie = arena.get_node("Zombies").get_child(0)
	z.activate(Transform3D(Basis.IDENTITY, Vector3(0, 0, -1)), arena.gladiator)
	z.set_physics_process(false)
	fx.clear_effects()
	var next_hit: int = fx._next[CombatFX.Kind.HIT]
	z.take_damage(5, Vector3.ZERO)
	arena.gladiator.dealt_damage.emit(5, z, Gladiator.AttackType.SWORD)
	check(fx._next[CombatFX.Kind.HIT] == (next_hit + 1) % fx.pool_per_effect, "one hit must emit blood exactly once")
	var active_bursts := 0
	for burst in fx._bursts:
		if burst.visible:
			active_bursts += 1
	check(active_bursts == 1, "one hit must display one generated splash")
	fx._process(0.4)
	check(not fx._bursts[0].visible, "blood burst must expire")
	var health_before := z.health
	next_hit = fx._next[CombatFX.Kind.HIT]
	z.stagger(0.8, Vector3.ZERO)
	fx._process(0.016)
	check(fx._stuns[0].visible, "shield stagger has no indicator")
	check(z.health == health_before and fx._next[CombatFX.Kind.HIT] == next_hit, "damage-free stun must not emit blood or alter health")
	var first_position: Vector3 = fx._stuns[0].get_child(1).position
	fx._process(0.2)
	check(first_position.distance_to(fx._stuns[0].get_child(1).position) > 0.02, "stun stars do not orbit")
	z.position.x += 2
	fx._process(0.016)
	check(is_equal_approx(fx._stuns[0].global_position.x, z.global_position.x), "stun does not follow displaced enemy")
	z.state = Zombie.State.CHASE
	fx._process(0.016)
	check(not fx._stuns[0].visible, "indicator survives expired stun")
	z.take_damage(1, Vector3.ZERO, 0, 3.0)
	fx._process(0.016)
	check(fx._stuns[0].visible, "kick stun has no indicator")
	z.deactivate()
	fx._process(0.016)
	check(not fx._stuns[0].visible, "indicator follows deactivated enemy below floor")
	z.set_variant(Zombie.Variant.BRUTE)
	z.activate(Transform3D.IDENTITY, arena.gladiator)
	z.stagger(1, Vector3.ZERO)
	fx._process(0.016)
	check(fx._stuns[0].global_position.y > 2.2, "brute indicator ignores character height")
	z.activate(Transform3D.IDENTITY, arena.gladiator)
	check(not fx._stuns[0].visible, "pooled respawn retains stun effect")
	var child_count := fx.get_child_count()
	for i in 50:
		fx.play_blood(Vector3.UP)
	check(fx.get_child_count() == child_count, "repeated hits allocate more effect nodes")
	fx.clear_effects()
	for burst in fx._bursts:
		check(not burst.visible, "arena reset retains blood")
	var quiet: Arena = load("res://scenes/Arena.tscn").instantiate()
	quiet.visuals_enabled = false
	quiet.pool_size = 1
	quiet.potion_pool_size = 0
	quiet.human_control = false
	root.add_child(quiet)
	quiet.set_physics_process(false)
	await process_frame
	var quiet_fx: CombatFX = quiet.get_node("CombatFX")
	check(quiet_fx._pools.is_empty() and quiet_fx._stuns.is_empty() and quiet_fx._bursts.is_empty(), "training creates visual pools")
	check(not quiet_fx.is_visible_in_tree() and not quiet_fx.is_processing(), "training runs visual effects")
	print("COMBAT_FX: %d checks, %d failures" % [checks, failures.size()])
	for message in failures:
		push_error(message)
	arena.free()
	quiet.free()
	quit(0 if failures.is_empty() else 1)

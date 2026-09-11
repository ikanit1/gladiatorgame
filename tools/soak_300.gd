extends Node

## 300 real seconds with rendering, combat, room transitions and periodic census.
## Run tools/soak_300.tscn; output is tools/diagnostics/soak_*.json / soak.csv.
var game: Node3D
var arena: Arena
var started_ms: int
var next_sample: int = 30
var simulated_seconds := 0.0
var frames := 0
var attacks := 0
var done := false
var initial_paths: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -30
	game = load("res://scenes/Game.tscn").instantiate()
	add_child(game)
	arena = game.get("arena")
	var controller: Node = arena.gladiator.get_node("PlayerInput")
	controller.process_mode = Node.PROCESS_MODE_DISABLED
	arena.gladiator.human_movement = false
	arena.gladiator.attack_started.connect(func(_kind: int): attacks += 1)
	started_ms = Time.get_ticks_msec()
	var csv := FileAccess.open("res://tools/diagnostics/soak.csv", FileAccess.WRITE)
	csv.store_line("wall_s,sim_s,nodes,orphans,objects,resources,static_mib,video_mib,rooms,room_nodes,kills,attacks")
	csv.close()
	_sample(0)
	print("SOAK_START pid=", OS.get_process_id(), " duration=300 real seconds, graphics=", RenderingServer.get_current_rendering_method())

func _process(_delta: float) -> void:
	if done:
		return
	# Test automation must keep advancing even when another app takes focus.
	if game.get("_upgrade_overlay").visible:
		for child in game.get("_upgrade_box").get_children():
			if child is Button and not child.is_queued_for_deletion():
				child.pressed.emit()
				break
	elif get_tree().paused and not game.get("_finished"):
		game._on_primary()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var elapsed := float(Time.get_ticks_msec() - started_ms) / 1000.0
	if elapsed >= next_sample:
		_sample(next_sample)
		next_sample += 30
	if elapsed >= 300.0:
		done = true
		print("SOAK_COMPLETE real_s=", elapsed, " sim_s=", simulated_seconds, " frames=", frames)
		get_tree().quit()

func _physics_process(delta: float) -> void:
	if done or arena == null or get_tree().paused:
		return
	frames += 1
	simulated_seconds += delta
	var g := arena.gladiator
	if g.is_downed():
		g.revive()
	g.health = g.max_health
	_drive(g)
	# Бой кончился - идём к открытой двери текущей комнаты. Старого выхода
	# (arena.exit_open/exit_position) больше нет: комнаты и двери теперь у
	# GameScreen, и он отдаёт наружу ближайшую открытую дверь.
	if not arena.get_alive_zombies().is_empty():
		return
	var room: DungeonRoom = game.current_room()
	var side := _door_to_walk(room, g.global_position)
	if room == null or side < 0:
		return
	var to_exit: Vector3 = room.door_position(side) - g.global_position
	to_exit.y = 0.0
	if to_exit.length() > 0.2:
		var angle := g.forward().signed_angle_to(to_exit.normalized(), Vector3.UP)
		g.intent_turn = -clampf(angle * 3.0, -1.0, 1.0)
		g.intent_move = 1.0
		g.intent_block = false


## Ближайшая открытая дверь, но с предпочтением ещё не посещённых соседей:
## просто ближайшая - это почти всегда дверь, через которую только что вошли,
## и прогон ходил бы туда-обратно между двумя комнатами, не строя новых.
func _door_to_walk(room: DungeonRoom, from: Vector3) -> int:
	if room == null:
		return -1
	var nearest: int = game.nearest_open_door(from)
	var run: RunState = game.get("_run")
	var fl: DungeonFloor = game.get("_floor")
	if run == null or fl == null:
		return nearest
	var best := -1
	var best_d := INF
	for side in room.open_sides():
		var cell: Vector2i = fl.current_cell + FloorPlan.SIDE_OFFSETS[side]
		if run.is_visited(cell):
			continue
		var d := from.distance_to(room.door_position(side))
		if d < best_d:
			best_d = d
			best = side
	return best if best >= 0 else nearest

func _drive(g: Gladiator) -> void:
	g.intent_move = 0.0
	g.intent_turn = 0.0
	g.intent_block = false
	var zombies := arena.get_alive_zombies()
	if zombies.is_empty():
		return
	var nearest: Zombie = zombies[0]
	var best := INF
	for zombie in zombies:
		var dist: float = zombie.global_position.distance_to(g.global_position)
		if dist < best:
			best = dist
			nearest = zombie
	var to_target := nearest.global_position - g.global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		return
	var angle := g.forward().signed_angle_to(to_target.normalized(), Vector3.UP)
	g.intent_turn = -clampf(angle * 3.0, -1.0, 1.0)
	g.intent_move = 1.0 if best > 1.8 else 0.0
	g.intent_sword = best < 2.1 and absf(angle) < 0.6
	g.intent_block = best < 2.6 and g.sword_cd > 0.25

func _built_rooms() -> int:
	var fl: Node = game.get("_floor")
	return fl.get_child_count() if fl != null else 0

func _census(node: Node, classes: Dictionary, paths: Array[String]) -> void:
	var kind := node.get_class()
	classes[kind] = int(classes.get(kind, 0)) + 1
	paths.append(str(node.get_path()))
	for child in node.get_children():
		_census(child, classes, paths)

func _sample(second: int) -> void:
	var row := {
		"wall_s": float(Time.get_ticks_msec() - started_ms) / 1000.0,
		"sim_s": simulated_seconds,
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"static_mib": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"video_mib": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"rooms": _built_rooms(),
		"room_nodes": 0,
		"kills": arena.total_kills,
		"attacks": attacks,
	}
	var classes: Dictionary = {}
	var paths: Array[String] = []
	_census(game, classes, paths)
	# Комнаты этажа живут в DungeonFloor у GameScreen, а не внутри Arena.
	var dungeon: Node = game.get("_floor")
	if dungeon != null:
		var room_paths: Array[String] = []
		var room_classes: Dictionary = {}
		_census(dungeon, room_classes, room_paths)
		row["room_nodes"] = room_paths.size()
	var csv := FileAccess.open("res://tools/diagnostics/soak.csv", FileAccess.READ_WRITE)
	csv.seek_end()
	var values := PackedStringArray()
	for key in ["wall_s", "sim_s", "nodes", "orphans", "objects", "resources", "static_mib", "video_mib", "rooms", "room_nodes", "kills", "attacks"]:
		values.append(str(row[key]))
	csv.store_line(",".join(values))
	csv.close()
	row["classes"] = classes
	row["paths"] = paths
	var fl: DungeonFloor = game.get("_floor")
	var run: RunState = game.get("_run")
	row["room_config"] = {
		"floor": run.floor_number if run != null else 0,
		"cell": str(fl.current_cell) if fl != null else "",
		"cleared": run.cleared.size() if run != null else 0,
	}
	var json := FileAccess.open("res://tools/diagnostics/soak_%03d.json" % second, FileAccess.WRITE)
	json.store_string(JSON.stringify(row, "\t"))
	json.close()
	print("SOAK ", second, "s nodes=", row.nodes, " mem=", snappedf(row.static_mib, 0.01), " MiB orphan=", row.orphans, " rooms=", row.rooms, " kills=", row.kills, " attacks=", attacks)

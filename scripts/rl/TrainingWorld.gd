extends Node3D

## Сцена обучения: сетка независимых арен + Sync-нода плагина.
##
## Почему арены создаются кодом, а не расставлены в .tscn: количество
## окружений - главный рычаг скорости обучения, и его надо менять одним
## числом, а не пересобирая сцену.
##
## Здесь же к каждому гладиатору цепляется GladiatorAIController. Благодаря
## этому ОСНОВНАЯ игра (Main.tscn) вообще не знает о плагине godot_rl_agents -
## её можно запускать и отлаживать без Python.

@export var arena_scene: PackedScene
@export var grid_cols: int = 4
@export var grid_rows: int = 4
## Шаг сетки. Обязан быть заметно больше дальности лидара (12 м), иначе лучи
## одной арены нащупают зомби соседней и наблюдения станут мусором.
@export var spacing: float = 40.0
@export var seed_base: int = 1000
## Обучение в паре: на арене два бойца, обоими управляет ОДНА И ТА ЖЕ
## политика (parameter sharing). SB3 видит их как отдельные окружения,
## поэтому 16 арен превращаются в 32 источника опыта.
@export var team_training: bool = true

const CONTROLLER := preload("res://scripts/rl/GladiatorAIController.gd")

var arenas: Array[Arena] = []


func _ready() -> void:
	if arena_scene == null:
		push_error("TrainingWorld: не задана arena_scene")
		return

	for i in grid_cols * grid_rows:
		_build_arena(i)

	var agents := arenas.size() * (2 if team_training else 1)
	print("TrainingWorld: арен %d (сетка %dx%d, шаг %.0f м), агентов %d, режим %s" % [
		arenas.size(), grid_cols, grid_rows, spacing, agents,
		"команда" if team_training else "одиночка"])


func _build_arena(index: int) -> void:
	var arena: Arena = arena_scene.instantiate()

	arena.human_control = false
	arena.visuals_enabled = false
	# Эпизодами управляет AIController, а не сама арена:
	# два независимых источника сброса рассинхронизировали бы наблюдения.
	arena.auto_reset = false
	# Разные сиды - разные точки спавна. Одинаковые сделали бы N копий
	# одного и того же опыта, и выборка PPO потеряла бы разнообразие.
	arena.arena_seed = seed_base + index
	arena.ally_enabled = team_training
	arena.ally_local_policy = false   # управляет AIController, а не локальная политика

	var col := index % grid_cols
	var row := index / grid_cols
	arena.position = Vector3(float(col) * spacing, 0.0, float(row) * spacing)

	add_child(arena)
	_attach_controller(arena.gladiator)
	if arena.ally != null:
		_attach_controller(arena.ally)
	arenas.append(arena)


func _attach_controller(fighter: Gladiator) -> void:
	var ctrl := CONTROLLER.new()
	ctrl.name = "AIController"
	ctrl.brain_path = ^"../Brain"
	fighter.add_child(ctrl)

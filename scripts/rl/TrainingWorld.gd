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

## Бегуны и громилы. Раньше было выключено, и напарник ни разу за обучение
## не встречал ни того, ни другого - а игра включает разновидности всегда.
## Тип ближайшего врага агент видит в наблюдениях, иначе отличить быстрого
## хилого от медленного толстого по одному кадру он бы не смог.
@export var variants_enabled: bool = true
@export var runner_from_wave: int = 3
@export var brute_from_wave: int = 5

## Темп боя берётся из «Нормальной» сложности игры, а не из значений по
## умолчанию в Arena.tscn: политику имеет смысл затачивать под тот режим,
## в котором в неё будут играть.
@export var first_wave_size: int = 3
@export var wave_growth: int = 1
@export var max_alive: int = 8
@export var wave_delay: float = 2.5
@export var potion_interval: float = 8.0
@export var max_potions: int = 3

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

	arena.variants_enabled = variants_enabled
	arena.runner_from_wave = runner_from_wave
	arena.brute_from_wave = brute_from_wave
	arena.first_wave_size = first_wave_size
	arena.wave_growth = wave_growth
	arena.max_alive = max_alive
	arena.wave_delay = wave_delay
	arena.potion_interval = potion_interval
	arena.max_potions = max_potions
	# Комнат при обучении нет: волны идут бесконечно, эпизод заканчивает
	# смерть бойца. Подъём напарника тоже выключен - лежачее состояние
	# размыло бы границу эпизода.
	arena.waves_in_room = 0
	arena.revive_enabled = false

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

class_name LocalAgent
extends Node3D

## Управляет гладиатором обученной политикой БЕЗ Python.
##
## Заменяет связку GladiatorAIController + Sync + train/play.py на время игры:
## наблюдения берутся у того же GladiatorBrain, а решение считает PolicyRunner
## прямо в движке. Благодаря этому кооператив запускается из меню одной кнопкой.

@export_file("*.policy") var policy_path: String = "res://models/gladiator_team_v5.policy"
@export var brain_path: NodePath = ^"../Brain"

## ОБЯЗАН совпадать с action_repeat, на котором политика обучалась (8).
## Если применять действие каждый физический шаг, агент будет бить в восемь
## раз чаще, чем привык, и поведение развалится - при том, что сеть та же.
@export var decision_period: int = 8

var ready_to_act: bool = false
var status: String = ""

var _brain: GladiatorBrain
var _runner: PolicyRunner
var _step: int = 0
var _action: PackedFloat32Array


func _ready() -> void:
	_brain = get_node_or_null(brain_path) as GladiatorBrain
	if _brain == null:
		status = "не найден GladiatorBrain"
		push_error("LocalAgent: " + status)
		set_physics_process(false)
		return

	_runner = PolicyRunner.new()
	if not _runner.load_from(policy_path):
		status = _runner.load_error
		push_error("LocalAgent: " + status)
		set_physics_process(false)
		return

	if _runner.obs_dim != _brain.get_observation_size():
		status = "политика ждёт %d наблюдений, игра даёт %d — модель устарела" % [
			_runner.obs_dim, _brain.get_observation_size()]
		push_error("LocalAgent: " + status)
		set_physics_process(false)
		return

	# Решения принимаем до того, как гладиатор прочитает намерения
	process_physics_priority = -15
	ready_to_act = true
	status = "политика загружена: %s" % policy_path.get_file()


func _physics_process(_delta: float) -> void:
	if not ready_to_act:
		return

	_step += 1
	# Новое решение раз в decision_period шагов, между ними держим прежнее -
	# ровно так же, как Sync подавал действия при обучении.
	if _action.is_empty() or _step % decision_period == 0:
		_action = _runner.predict(_brain.get_observation())

	_brain.apply_action(_action)
	_brain.step()
	# Награду здесь никто не читает, но копить её нельзя: иначе счётчик
	# эпизода растёт без границ и статистика в HUD врёт.
	_brain.consume_reward()

	if _brain.done:
		_brain.reset()

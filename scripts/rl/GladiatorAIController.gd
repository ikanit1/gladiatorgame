extends AIController3D

## ТОНКИЙ АДАПТЕР между godot_rl_agents и GladiatorBrain.
##
## Здесь нет ни одной строчки логики наград или наблюдений - только перевод
## между API плагина и Brain. Если менять RL-фреймворк, переписывается
## только этот файл.

@export var brain_path: NodePath = ^"../Brain"

var _brain: GladiatorBrain
var _episode_over: bool = false


func _ready() -> void:
	super._ready()                     # add_to_group("AGENT")
	_brain = get_node_or_null(brain_path) as GladiatorBrain
	if _brain == null:
		push_error("GladiatorAIController: не найден GladiatorBrain по пути " + str(brain_path))
		set_physics_process(false)
		return

	# Длиной эпизода управляет Brain, дублировать её в двух местах нельзя
	reset_after = _brain.max_episode_steps


func _physics_process(delta: float) -> void:
	super._physics_process(delta)      # n_steps += 1, needs_reset при переполнении
	if _brain == null:
		return

	if _episode_over:
		# ПОДВОХ: sync.gd НЕ вызывает agent.reset() (строка закомментирована),
		# перезапуск окружения - наша забота. Но перезапускать сразу нельзя:
		# Sync читает done позже, и первое наблюдение нового эпизода уехало бы
		# в Python помеченным как терминальное. Ждём, пока Sync прочитает флаг
		# (после чтения он сам ставит done = false), и только тогда сбрасываем.
		if not done or heuristic == "human":
			_restart()
		return

	_brain.step()
	# Награда копится между решениями: при action_repeat = 8 на одно решение
	# приходится 8 физических шагов, и награду за 7 из них нельзя терять.
	reward += _brain.consume_reward()

	if _brain.done or needs_reset:
		_episode_over = true
		done = true


func _restart() -> void:
	_episode_over = false
	_brain.reset_environment()
	reset()                            # n_steps = 0, needs_reset = false
	reward = 0.0


# ------------------------------------------------------------------
# Контракт godot_rl_agents
# ------------------------------------------------------------------

func get_obs() -> Dictionary:
	return {"obs": _brain.get_observation()}


func get_reward() -> float:
	return reward


## SB3 не поддерживает смешанные (Dict/Tuple) пространства действий, поэтому
## всё непрерывное: атаки и блок срабатывают по порогу внутри Brain.
func get_action_space() -> Dictionary:
	return {
		"movement": {"size": 2, "action_type": "continuous"},   # ход, поворот
		"combat": {"size": 3, "action_type": "continuous"},     # меч, пинок, блок
	}


func set_action(action) -> void:
	if _brain == null:
		return
	var mv = action["movement"]
	var cb = action["combat"]
	_brain.apply_action(PackedFloat32Array([mv[0], mv[1], cb[0], cb[1], cb[2]]))


## Уходит в Python и попадает в логи обучения - удобно смотреть, растут ли
## убийства и волны, а не только суммарная награда.
func get_info() -> Dictionary:
	return _brain.get_stats()

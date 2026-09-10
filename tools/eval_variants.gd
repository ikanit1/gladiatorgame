extends Node

## Проверка того, ради чего добавлялся признак типа врага в наблюдения:
## ведёт ли обученная политика себя ПО-РАЗНОМУ против бегуна и громилы.
##
## Просто «награда выросла» на этот вопрос не отвечает. Если бы агент
## игнорировал новый признак, он всё равно набрал бы неплохую награду -
## усреднённой тактикой. Разницу видно только в поведении: против хилого
## быстрого бегуна выгодно бить, против живучего громилы - держать щит и
## разрывать дистанцию.
##
## Состав волны навязывается снаружи, а не через _pick_variant: тот выдаёт
## смесь по вероятностям, и чистого замера по одному типу из него не выйдет.

const SECONDS_PER_RUN := 60.0
const POLICY := "res://models/gladiator_team_v5.policy"

var _arena: Arena
var _forced: int = 0
var _t: float = 0.0

# Замеры за прогон
var _kills: int = 0
var _dealt: float = 0.0
var _taken: float = 0.0
var _blocked: float = 0.0
var _attacks: int = 0
var _misses: int = 0
var _block_frames: int = 0
var _frames: int = 0
var _dist_sum: float = 0.0
var _dist_n: int = 0
var _deaths: int = 0

var _results: Array = []
var _names := {0: "обычные", 1: "бегуны", 2: "громилы"}


func _ready() -> void:
	# Именно FileAccess, а не ResourceLoader: .policy - сырой бинарник со
	# своим заголовком, Godot его не импортирует, и ResourceLoader.exists
	# на существующий файл отвечает false.
	if not FileAccess.file_exists(POLICY):
		print("нет файла политики: " + POLICY)
		get_tree().quit(1)
		return

	# Сначала самопроверка прямого прохода. В файле политики лежат
	# контрольные пары obs->action, снятые с PyTorch при выгрузке. Если
	# реализация на GDScript разойдётся с ними, все замеры поведения ниже
	# будут описывать не ту сеть, что обучалась, - и разница между типами
	# врагов оказалась бы артефактом арифметики, а не тактикой агента.
	var runner := PolicyRunner.new()
	if not runner.load_from(POLICY):
		print("политика не загрузилась")
		get_tree().quit(1)
		return
	var check := runner.verify()
	print("самопроверка сети: пар %d, максимальное расхождение %.9f" % [
		check["samples"], check["max_diff"]])
	if not bool(check.get("ok", check["max_diff"] < 1.0e-3)):
		print("ПРОВАЛ: прямой проход на GDScript расходится с PyTorch")
		get_tree().quit(1)
		return

	for variant in [0, 1, 2]:
		await _run_one(variant)
	_report()
	get_tree().quit()


func _run_one(variant: int) -> void:
	_forced = variant
	_reset_stats()

	var scene: PackedScene = load("res://scenes/Arena.tscn")
	_arena = scene.instantiate()
	_arena.human_control = false
	_arena.visuals_enabled = false
	_arena.auto_reset = true
	_arena.ally_enabled = false
	_arena.variants_enabled = true
	_arena.arena_seed = 4242
	# Темп боя тот же, что при обучении и в «Нормальной» сложности
	_arena.first_wave_size = 3
	_arena.wave_growth = 1
	_arena.max_alive = 8
	_arena.wave_delay = 2.5
	_arena.waves_in_room = 0
	add_child(_arena)
	await get_tree().physics_frame

	var g: Gladiator = _arena.gladiator
	var agent := LocalAgent.new()
	agent.name = "LocalAgent"
	agent.policy_path = POLICY
	g.add_child(agent)
	await get_tree().physics_frame
	# status у LocalAgent - человекочитаемое состояние, а не только ошибка:
	# при успехе там лежит «политика загружена: ...». Признак беды - не
	# непустая строка, а отсутствие готовности действовать.
	if not agent.ready_to_act:
		print("политика не запустилась: " + agent.status)

	g.dealt_damage.connect(func(a, _t2, _ty): _dealt += a)
	g.enemy_killed.connect(func(_t2): _kills += 1)
	g.took_damage.connect(func(a, _b): _taken += a)
	g.damage_blocked.connect(func(a): _blocked += a)
	g.attack_started.connect(func(_ty): _attacks += 1)
	g.attack_missed.connect(func(_ty): _misses += 1)
	g.died.connect(func(): _deaths += 1)

	_t = 0.0
	while _t < SECONDS_PER_RUN:
		await get_tree().physics_frame
		_t += get_physics_process_delta_time()
		_force_variant()
		_sample(g)

	_results.append({
		"variant": variant, "kills": _kills, "dealt": _dealt, "taken": _taken,
		"blocked": _blocked, "attacks": _attacks, "misses": _misses,
		"block_share": float(_block_frames) / maxf(float(_frames), 1.0),
		"dist": _dist_sum / maxf(float(_dist_n), 1.0), "deaths": _deaths,
	})

	_arena.queue_free()
	await get_tree().process_frame


## Навязываем тип каждому только что появившемуся зомби.
##
## set_variant пересчитывает характеристики, но НЕ трогает текущее здоровье:
## activate() уже выставил его по прежнему максимуму. Без явной досылки
## громила выходил бы в бой с запасом обычного зомби, и весь замер поехал бы.
func _force_variant() -> void:
	for z in _arena.get_alive_zombies():
		if z.variant != _forced:
			z.set_variant(_forced)
			z.health = z.max_health


func _sample(g: Gladiator) -> void:
	_frames += 1
	if g.is_blocking:
		_block_frames += 1
	var near := INF
	for z in _arena.get_alive_zombies():
		var d: float = z.global_position.distance_to(g.global_position)
		near = minf(near, d)
	if near < INF:
		_dist_sum += near
		_dist_n += 1


func _reset_stats() -> void:
	_kills = 0
	_dealt = 0.0
	_taken = 0.0
	_blocked = 0.0
	_attacks = 0
	_misses = 0
	_block_frames = 0
	_frames = 0
	_dist_sum = 0.0
	_dist_n = 0
	_deaths = 0


func _report() -> void:
	print("")
	print("=== поведение политики против одного типа врага, по %.0f с на тип ===" % SECONDS_PER_RUN)
	print("тип       убито  урон   получено  блок(HP)  щит(доля)  атак  промах%  дист(м)  смертей")
	for r in _results:
		var miss_pct := 100.0 * float(r["misses"]) / maxf(float(r["attacks"]), 1.0)
		print("%-9s %5d  %5.0f  %8.0f  %8.0f  %8.2f  %5d  %6.0f  %7.2f  %7d" % [
			_names[r["variant"]], r["kills"], r["dealt"], r["taken"], r["blocked"],
			r["block_share"], r["attacks"], miss_pct, r["dist"], r["deaths"]])

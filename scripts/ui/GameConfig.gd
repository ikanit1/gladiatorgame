extends Node

## Настройки игры (автозагрузка). Хранятся в user://settings.cfg.
##
## Держим их отдельным синглтоном, а не в сцене: меню, игра и экран паузы
## обращаются к одним и тем же значениям, и пробрасывать их через сцены
## пришлось бы вручную на каждом переходе.

const PATH := "user://settings.cfg"
const MODELS_DIR := "res://models"

## Слабый старт забега. Нужен, чтобы редкий сундук ощущался наградой: при
## нынешних ста единицах здоровья и кулдауне 0.7 игрок и без апгрейдов
## проходит первые комнаты не напрягаясь.
##
## Урон меча не трогаем намеренно: «два удара на зомби» - дизайн-решение с
## комментарием в Zombie.gd, иначе пинок и блок становятся ненужными. Зомби
## станет трёхударным сам, за счёт роста здоровья в ThreatCurve.
const START_MAX_HEALTH := 70.0
const START_BLOCK_STAMINA := 70.0
const START_SWORD_COOLDOWN := 0.85
const START_KICK_COOLDOWN := 2.2

enum Difficulty { EASY, NORMAL, HARD }

var coop: bool = true
var ally_policy: String = "res://models/gladiator_team_v5.policy"
var difficulty: int = Difficulty.NORMAL
var master_volume: float = 0.8
var show_ai_debug: bool = false

## Множитель глубины под выбранную сложность. Применяется к threat, а не к
## полям арены: так одна кривая обслуживает все три режима.
var difficulty_threat_mult: float = 1.0

# Последний бой - для экрана результатов
var last_result: Dictionary = {}


func _ready() -> void:
	load_settings()
	apply_volume()


# ------------------------------------------------------------------

func difficulty_name(d: int = -1) -> String:
	match (difficulty if d < 0 else d):
		Difficulty.EASY: return "Спокойная"
		Difficulty.HARD: return "Жестокая"
		_: return "Обычная"


## Единственное место, где сложность превращается в числа арены.
func apply_to_arena(arena: Arena) -> void:
	arena.human_control = true
	arena.visuals_enabled = true
	arena.auto_reset = false
	arena.ally_enabled = coop
	arena.ally_policy = ally_policy
	# Рогалик-механики живут только в игре; обучение идёт на базовом балансе
	arena.revive_enabled = true
	arena.variants_enabled = true

	match difficulty:
		Difficulty.EASY:
			arena.max_potions = 3
			difficulty_threat_mult = 0.75
		Difficulty.HARD:
			arena.max_potions = 2
			difficulty_threat_mult = 1.3
		_:
			arena.max_potions = 3
			difficulty_threat_mult = 1.0


## Статический намеренно: проверка запускается через --script, где автозагрузок
## не существует, и зовёт метод у загруженного ресурса скрипта. Из игры
## по-прежнему доступен как GameConfig.apply_weak_start().
##
## Здоровье и запас щита выставляются в новый максимум, а не через minf, как
## было в плане: у бойца до _ready() health ещё равен нулю (Gladiator ставит
## его в _ready), и minf оставил бы ноль. Звать один раз, на старте забега,
## у свежих бойцов - на раненом бойце вызов его бы подлечил.
static func apply_weak_start(fighters: Array) -> void:
	for f in fighters:
		if f == null:
			continue
		f.max_health = START_MAX_HEALTH
		f.health = START_MAX_HEALTH
		f.block_stamina_max = START_BLOCK_STAMINA
		f.block_stamina = START_BLOCK_STAMINA
		f.sword_cooldown = START_SWORD_COOLDOWN
		f.kick_cooldown = START_KICK_COOLDOWN


## Сложность применяется ПОСЛЕ генерации комнаты: планировку задаёт
## RoomGenerator, а темп боя - выбор игрока.
func apply_difficulty_to_room(arena: Arena) -> void:
	match difficulty:
		Difficulty.EASY:
			arena.max_alive = maxi(3, int(arena.max_alive * 0.7))
			arena.wave_delay = 3.5
			arena.max_potions = 3
		Difficulty.HARD:
			arena.max_alive = int(arena.max_alive * 1.4)
			arena.wave_delay = 1.4
			arena.max_potions = 2
			arena.potion_interval += 2.0
		_:
			arena.wave_delay = 2.5


## Список политик, которые можно поставить напарнику.
func available_policies() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(MODELS_DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		# В экспортированной сборке ресурсы получают суффикс .remap
		var name := f.trim_suffix(".remap")
		if name.ends_with(".policy"):
			out.append(MODELS_DIR + "/" + name)
	out.sort()
	return out


func apply_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if master_volume <= 0.001:
		AudioServer.set_bus_mute(bus, true)
	else:
		AudioServer.set_bus_mute(bus, false)
		AudioServer.set_bus_volume_db(bus, linear_to_db(master_volume))


# ------------------------------------------------------------------

func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "coop", coop)
	cfg.set_value("game", "ally_policy", ally_policy)
	cfg.set_value("game", "difficulty", difficulty)
	cfg.set_value("game", "show_ai_debug", show_ai_debug)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.save(PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	coop = cfg.get_value("game", "coop", coop)
	ally_policy = cfg.get_value("game", "ally_policy", ally_policy)
	difficulty = cfg.get_value("game", "difficulty", difficulty)
	show_ai_debug = cfg.get_value("game", "show_ai_debug", show_ai_debug)
	master_volume = cfg.get_value("audio", "master_volume", master_volume)

	# Модель могли удалить или переименовать между запусками
	if not ResourceLoader.exists(ally_policy) and not FileAccess.file_exists(ally_policy):
		var found := available_policies()
		ally_policy = found[0] if not found.is_empty() else ""

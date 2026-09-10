extends CanvasLayer

## Отладочный HUD. Показывает ровно те величины, которые пойдут в вектор
## наблюдений - удобно глазами проверять, что они нормализованы и не залипают.

@export var arena_path: NodePath

@onready var _hp_fill: ColorRect = $HpFill
@onready var _st_fill: ColorRect = $StFill
@onready var _sword_fill: ColorRect = $SwordFill
@onready var _kick_fill: ColorRect = $KickFill
@onready var _hp_label: Label = $HpLabel
@onready var _info: Label = $Info
@onready var _hints: Label = $Hints

var _arena: Arena

# Полная ширина полосок запоминается на старте: дальше меняем только size.x
var _hp_w: float
var _st_w: float
var _sword_w: float
var _kick_w: float


func _ready() -> void:
	_arena = get_node_or_null(arena_path) as Arena
	_hp_w = _hp_fill.size.x
	_st_w = _st_fill.size.x
	_sword_w = _sword_fill.size.x
	_kick_w = _kick_fill.size.x

	_hints.text = "\n".join([
		"W/S - вперёд-назад      A/D - поворот",
		"Space - меч      E - пинок      Shift - блок      R - сброс арены",
	])


func _process(_delta: float) -> void:
	if _arena == null:
		return

	var g := _arena.gladiator
	var alive := g.is_alive()

	_hp_fill.size.x = _hp_w * (g.get_health_ratio() if alive else 0.0)
	_st_fill.size.x = _st_w * g.get_block_stamina_ratio()
	_sword_fill.size.x = _sword_w * clampf(g.get_sword_ready_ratio(), 0.0, 1.0)
	_kick_fill.size.x = _kick_w * clampf(g.get_kick_ready_ratio(), 0.0, 1.0)

	# Щит светится, пока держим блок - видно, что механика реально включена
	_st_fill.color = Color(0.55, 0.85, 1.0) if g.is_blocking else Color(0.35, 0.62, 0.88)

	if not alive:
		_hp_label.text = "ПОГИБ — перезапуск..."
		_info.text = "Волна %d      Убито %d" % [_arena.wave_index, _arena.total_kills]
		return

	_hp_label.text = "HP  %d / %d" % [roundi(g.health), roundi(g.max_health)]

	var state := "блок" if g.is_blocking else "—"
	if g.stun_time > 0.0:
		state = "СТАН %.1f" % g.stun_time
	elif g.action_lock > 0.0:
		state = "восст. %.2f" % g.action_lock

	_info.text = "\n".join([
		"Волна %d      Зомби %d      Убито %d" % [
			_arena.wave_index, _arena.get_alive_count(), _arena.total_kills],
		"Состояние: %s" % state,
		"Меч %.2f    Пинок %.2f    Щит %.2f" % [
			g.get_sword_ready_ratio(), g.get_kick_ready_ratio(), g.get_block_stamina_ratio()],
	])

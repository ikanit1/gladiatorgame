extends Node3D

## Игровая сцена: этаж по сетке, бой за комнату, HUD на двоих, пауза и итоги.
##
## Арена создаётся кодом, а не стоит в .tscn инстансом. Причина простая:
## Arena._ready() выполняется раньше, чем _ready() родителя, и настройки
## (кооператив, сложность) успели бы опоздать - арена уже собрала бы пул
## и запустила первую волну по значениям из .tscn.

const MENU_SCENE := "res://scenes/ui/MainMenu.tscn"

## Сколько секунд держится подсказка по управлению при входе в комнату
const HINT_SECONDS := 12.0

@export var arena_scene: PackedScene
## Сид забега; 0 - случайный. Задаётся до _ready (например, проверкой
## tools/check_game_floor.gd): от него зависят планировка этажа, контуры
## комнат, состав врагов и клетки их спавна.
@export var run_seed: int = 0

var arena: Arena
## Навигация по этажу: комнаты, двери, бой за комнату, состояние забега.
## GameScreen только рисует то, что она сообщает; проверки и инструменты
## ходят в неё напрямую.
var floor_runner: FloorRunner
var _elapsed: float = 0.0
var _finished: bool = false

@onready var _rig: SpringArm3D = $CameraRig

var _hud: Control
var _p_bar: HudBar
var _p_guard: HudBar
var _ally_panel: PanelContainer
var _a_bar: HudBar
var _chips: Dictionary = {}
var _overlay: Control
var _overlay_title: Label
var _overlay_text: Label
var _upgrade_overlay: Control
var _upgrade_box: VBoxContainer
var _revive_box: PanelContainer
var _revive_bar: HudBar
var _revive_label: Label
var _hint_box: Label
var _hint_time: float = HINT_SECONDS
var _toast: Label
var _toast_time: float = 0.0
var _door_hint: Label

# --- Ощущение удара ---
## Хит-стоп замедляет ВСЮ игру, поэтому он существует только здесь, в игровой
## сцене. При обучении Sync сам выставляет Engine.time_scale под --speedup,
## и вмешательство отсюда сломало бы темп симуляции.
@export var hitstop_scale: float = 0.06
@export var hitstop_deal: float = 0.045     ## свой удар - короткая задержка
@export var hitstop_taken: float = 0.075    ## получил сам - подольше
@export var hitstop_kill: float = 0.09
var _stop_until_ms: int = 0


func _ready() -> void:
	_build_arena()
	_build_hud()
	# После HUD: FloorRunner сообщает о входе в комнату сигналами, и к первому
	# из них подсказки и тосты уже должны существовать. RunState он создаёт
	# сразу, в setup, - HUD и итоги читают его с первого же кадра.
	_build_floor_runner()
	# Первый этаж строится ОТЛОЖЕННО. Arena._ready() ставит свой
	# reset_arena.call_deferred() в ту же очередь, и если войти в комнату
	# раньше, этот reset погасит только что расставленных врагов и вернёт
	# бойцов на стартовую позицию арены. Отложенные вызовы выполняются в
	# порядке постановки, а арена добавлена в дерево раньше - значит её reset
	# отработает первым.
	floor_runner.start_floor.call_deferred(1)
	_capture_mouse(true)
	set_process_input(true)


func _build_arena() -> void:
	if arena_scene == null:
		push_error("GameScreen: не задана arena_scene")
		return

	arena = arena_scene.instantiate()
	GameConfig.apply_to_arena(arena)   # обязательно ДО add_child
	# Комната - один бой: набор врагов приходит от GameScreen через
	# spawn_encounter, арена сама волн не заводит.
	arena.encounter_driven = true
	arena.waves_in_room = 1
	# Таймерный спавн зелий в игре выключен: зелье каждые восемь секунд и было
	# одной из причин, почему в бою не чувствовалось давления. В обучении
	# таймер остаётся - ближайшее зелье входит в наблюдения и в награду.
	arena.potion_interval = 1.0e9
	if run_seed != 0:
		# Клетки спавна выбирает генератор арены - при заданном сиде забега он
		# тоже обязан повторяться.
		arena.arena_seed = run_seed + 1
	add_child(arena)
	# После add_child: у бойцов до их _ready() здоровье ещё не выставлено
	# (см. GameConfig.apply_weak_start).
	GameConfig.apply_weak_start(arena.get_fighters())

	arena.episode_ended.connect(_on_episode_ended)
	arena.fighter_downed.connect(_on_fighter_downed)
	arena.fighter_revived.connect(_on_fighter_revived)
	# encounter_cleared слушает FloorRunner: зачистка - это навигация этажа.
	_bind_juice()

	# Камера следит за игроком, а не за напарником
	if _rig != null and _rig.has_method("set_target"):
		_rig.set_target(arena.gladiator)


func _process(delta: float) -> void:
	if arena == null or _finished:
		return
	_elapsed += delta

	if _toast_time > 0.0:
		_toast_time -= delta
		if _toast_time <= 0.0:
			_toast.visible = false

	_update_hud(delta)
	_update_hit_stop()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _finished:
			_to_menu()
		else:
			_toggle_pause()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_inside_tree():
		if is_instance_valid(_overlay) and not _finished and not get_tree().paused:
			_toggle_pause()


# ------------------------------------------------------------------
# HUD
# ------------------------------------------------------------------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_hud = Control.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.theme = UITheme.theme()
	layer.add_child(_hud)

	_build_fighter_panels()
	_build_chips()
	_build_revive_bar()
	_build_notices()

	_build_overlay(layer)
	_build_upgrade_overlay(layer)


## Панели бойцов слева сверху. Раньше содержимое клалось на _hud абсолютными
## координатами в обход панели, потому что PanelContainer сжимал вложенные
## Control. Причина была не в PanelContainer, а в том, что вложенные узлы не
## сообщали минимальный размер: контейнеру нечего было раскладывать. Полосы
## теперь настоящие Control с custom_minimum_size, и вложение работает.
func _build_fighter_panels() -> void:
	var col := VBoxContainer.new()
	col.position = Vector2(16, 16)
	col.custom_minimum_size = Vector2(320, 0)
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(col)

	# --- Игрок ---
	var p_panel := PanelContainer.new()
	p_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.82))
	p_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(p_panel)

	var p_box := VBoxContainer.new()
	p_box.add_theme_constant_override("separation", 6)
	p_panel.add_child(p_box)
	p_box.add_child(_caption_row("helmet", "ГЛАДИАТОР", UITheme.DIM))

	_p_bar = HudBar.new(276, 24, UITheme.DANGER, true)
	# Ниже трети здоровья полоса начинает пульсировать. Это единственный
	# сигнал о критическом состоянии: цифры в бою читать некогда.
	_p_bar.pulse_below = 0.33
	p_box.add_child(_p_bar)

	# Полоса щита подписана глифом, а не словом «щит»: отдельная строка
	# подписи стоила бы ещё 14 пикселей высоты панели, а иконка слева от
	# полосы не стоит ничего и читается быстрее текста.
	var guard_row := HBoxContainer.new()
	guard_row.add_theme_constant_override("separation", 6)
	guard_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	guard_row.add_child(UITheme.icon_rect("shield", 14, UITheme.GUARD))
	_p_guard = HudBar.new(256, 14, UITheme.GUARD, false)
	guard_row.add_child(_p_guard)
	p_box.add_child(guard_row)

	# --- Напарник ---
	# Панель создаётся всегда, но в одиночной игре скрыта. Держать её пустой
	# на экране, как было раньше, значит показывать полосу здоровья того,
	# кого в бою нет.
	_ally_panel = PanelContainer.new()
	_ally_panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.82))
	_ally_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ally_panel.visible = false
	col.add_child(_ally_panel)

	var a_box := VBoxContainer.new()
	a_box.add_theme_constant_override("separation", 6)
	_ally_panel.add_child(a_box)
	a_box.add_child(_caption_row("helmet", "НАПАРНИК · ИИ", UITheme.ACCENT))

	_a_bar = HudBar.new(276, 22, UITheme.ALLY, true)
	a_box.add_child(_a_bar)

	# Если политика напарника не подошла (например, обучена на старом наборе
	# наблюдений), он просто стоит столбом. Молча это выглядит как баг игры,
	# поэтому причину показываем прямо на экране.
	if arena != null and arena.ally != null and arena.ally_status.begins_with("политика ждёт"):
		var warn := UITheme.label("Напарник не активен: " + arena.ally_status,
			12, UITheme.DANGER)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn.custom_minimum_size = Vector2(276, 0)
		a_box.add_child(warn)


func _caption_row(icon_name: String, text: String, color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(UITheme.icon_rect(icon_name, 14, color))
	row.add_child(UITheme.title(text, 12, color, 3))
	return row


## Строка состояния забега сверху по центру.
##
## Была одной длинной строкой в левом краю: «Комната 1 Волна 1/2 · всего 1
## Убито 0 Зомби 2 0:09». Такую строку нельзя прочитать боковым зрением -
## глаз не знает, где кончается одно число и начинается другое. Иконка
## перед каждым значением решает это без всяких подписей.
func _build_chips() -> void:
	# У подписей есть обводка, у иконок её нет: на светлом песке арены глифы
	# без подложки пропадают. Подложка плоская - см. UITheme.pill_style.
	var back := PanelContainer.new()
	back.add_theme_stylebox_override("panel", UITheme.pill_style())
	back.set_anchors_preset(Control.PRESET_CENTER_TOP)
	back.grow_horizontal = Control.GROW_DIRECTION_BOTH
	back.position = Vector2(0, 10)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(back)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.add_child(row)

	# Монеты - на месте бывшего счётчика волн. Глифа монеты в наборе нет,
	# поэтому значение подписано словом (см. _update_hud).
	for spec in [["arch", "room", UITheme.FG], ["emblem", "coins", UITheme.FG],
			["skull", "kills", UITheme.FG], ["sword", "alive", UITheme.DANGER],
			["hourglass", "time", UITheme.FG]]:
		var chip := HBoxContainer.new()
		chip.add_theme_constant_override("separation", 6)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ic := UITheme.icon_rect(str(spec[0]), 21, spec[2])
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		chip.add_child(ic)
		var value := UITheme.label("", 16, UITheme.FG, 3)
		value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chip.add_child(value)
		_chips[str(spec[1])] = value
		row.add_child(chip)


func _build_revive_bar() -> void:
	_revive_box = PanelContainer.new()
	_revive_box.add_theme_stylebox_override("panel", UITheme.panel_style(0.9))
	_revive_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_revive_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_revive_box.position = Vector2(0, -160)
	_revive_box.visible = false
	_revive_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_revive_box)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	_revive_box.add_child(box)

	_revive_label = UITheme.label("", 13, UITheme.FG)
	_revive_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_revive_label.custom_minimum_size = Vector2(340, 0)
	box.add_child(_revive_label)

	_revive_bar = HudBar.new(340, 16, UITheme.ACCENT, false)
	# Подъём напарника - действие игрока, а не урон: сглаживание здесь
	# только запаздывало бы за клавишей.
	_revive_bar.smooth_speed = 0.0
	box.add_child(_revive_bar)


func _build_notices() -> void:
	_door_hint = UITheme.label("", 16, UITheme.GOOD)
	_door_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_door_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_door_hint.position = Vector2(0, -112)
	_door_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_door_hint.visible = false
	_hud.add_child(_door_hint)
	# 13b: подсказка о сундуке и люке строкой выше двери (_chest_hint).

	_toast = UITheme.label("", 18, UITheme.ACCENT)
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.position = Vector2(0, 54)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	_hud.add_child(_toast)

	# Подсказка по управлению нужна первые секунды, дальше это просто мусор
	# в углу. Гаснет сама и возвращается при каждом входе в новую комнату.
	_hint_box = UITheme.label(
		"WASD — движение · ЛКМ — меч · ПКМ — щит · E — пинок · F — поднять · Esc — пауза",
		12, UITheme.DIM)
	_hint_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint_box.position = Vector2(18, -34)
	_hud.add_child(_hint_box)


func _update_hud(delta: float) -> void:
	var g := arena.gladiator
	_p_bar.set_ratio(g.get_health_ratio() if g.is_alive() else 0.0)
	_p_bar.set_text("%d / %d" % [roundi(g.health), roundi(g.max_health)]
		if g.is_alive() else "ПАЛ")
	_p_guard.set_ratio(g.get_block_stamina_ratio())

	_ally_panel.visible = arena.ally != null
	if arena.ally != null:
		var a := arena.ally
		_a_bar.set_ratio(a.get_health_ratio() if a.is_alive() else 0.0)
		_a_bar.set_text("%d / %d" % [roundi(a.health), roundi(a.max_health)]
			if a.is_alive() else "пал")

	var run := floor_runner.run_state()
	# Этаж и число зачищенных комнат этажа: «1-3» - первый этаж, три комнаты.
	_chips["room"].text = "%d-%d" % [run.floor_number, run.cleared.size()]
	# Словом, а не голой цифрой: раньше на этом месте стояли волны «1/2», и
	# одинокое число читалось бы как они же.
	_chips["coins"].text = "монеты %d" % run.coins
	_chips["kills"].text = str(arena.total_kills)
	_chips["alive"].text = str(arena.get_alive_count())
	_chips["time"].text = "%d:%02d" % [int(_elapsed) / 60, int(_elapsed) % 60]

	if _hint_time > 0.0:
		_hint_time -= delta
		_hint_box.modulate.a = clampf(_hint_time, 0.0, 1.0)
		_hint_box.visible = _hint_time > 0.0

	_update_revive_ui()
	_update_room()


func _update_revive_ui() -> void:
	var downed: Gladiator = null
	for f in arena.get_fighters():
		if f.is_downed():
			downed = f
			break

	if downed == null:
		_revive_box.visible = false
		return

	_revive_box.visible = true
	_revive_bar.set_ratio(arena.revive_progress)
	var who := "Напарник" if downed != arena.gladiator else "Вы"
	if arena.revive_progress > 0.0:
		_revive_label.text = "%s: подъём…" % who
	else:
		_revive_label.text = "%s повержен — подойди и держи F   (%d с)" % [
			who, int(ceil(downed.downed_time_left))]


func _show_toast(text: String) -> void:
	_toast.text = text
	_toast.visible = true
	_toast_time = 2.5


func _on_fighter_downed(f: Gladiator) -> void:
	_show_toast("Напарник повержен!" if f != arena.gladiator else "Вы повержены")


func _on_fighter_revived(f: Gladiator) -> void:
	_show_toast("Напарник снова в строю" if f != arena.gladiator else "Вы поднялись")




# ------------------------------------------------------------------
# Ощущение удара: хит-стоп и тряска
# ------------------------------------------------------------------

func _bind_juice() -> void:
	var g := arena.gladiator
	g.dealt_damage.connect(_on_juice_dealt)
	g.enemy_killed.connect(_on_juice_kill)
	g.took_damage.connect(_on_juice_taken)
	g.damage_blocked.connect(_on_juice_blocked)
	g.guard_broken.connect(_on_juice_guard_break)
	g.attack_started.connect(_on_juice_attack)


## Отсчёт по реальным миллисекундам, а не по delta: delta сам умножен на
## time_scale, и заморозка продлевала бы себя до бесконечности.
func _hit_stop(duration: float) -> void:
	_stop_until_ms = maxi(_stop_until_ms, Time.get_ticks_msec() + int(duration * 1000.0))


func _update_hit_stop() -> void:
	if get_tree().paused:
		return
	Engine.time_scale = hitstop_scale if Time.get_ticks_msec() < _stop_until_ms else 1.0


func _shake(amount: float) -> void:
	if _rig != null and _rig.has_method("shake"):
		_rig.shake(amount)


func _on_juice_dealt(_amount: float, _target: Node3D, type: int) -> void:
	# Пинок глухой и тяжёлый, меч - резкий: разная длительность заморозки
	if type == Gladiator.AttackType.KICK:
		_hit_stop(hitstop_deal * 1.6)
		_shake(0.42)
	else:
		_hit_stop(hitstop_deal)
		_shake(0.26)


func _on_juice_kill(_target: Node3D) -> void:
	_hit_stop(hitstop_kill)
	_shake(0.5)


func _on_juice_taken(amount: float, blocked: bool) -> void:
	if blocked:
		return
	_hit_stop(hitstop_taken)
	# Чем больнее, тем сильнее трясёт - удар громилы должен ощущаться иначе
	_shake(clampf(0.45 + amount / arena.gladiator.max_health * 1.6, 0.45, 1.0))


func _on_juice_blocked(_absorbed: float) -> void:
	_hit_stop(hitstop_deal * 0.8)
	_shake(0.34)


func _on_juice_guard_break() -> void:
	_hit_stop(0.12)
	_shake(0.85)


func _on_juice_attack(type: int) -> void:
	if type == Gladiator.AttackType.KICK:
		_shake(0.12)


func _exit_tree() -> void:
	# Сцену можно покинуть в момент заморозки - вернуть время обязаны мы
	Engine.time_scale = 1.0


# ------------------------------------------------------------------
# Этаж и комнаты
# ------------------------------------------------------------------
# Сама навигация - в FloorRunner (scripts/run/FloorRunner.gd). Здесь только
# то, что игрок видит и чем управляет: подсказки, тосты, камера и ввод.

func _build_floor_runner() -> void:
	floor_runner = FloorRunner.new()
	floor_runner.name = "FloorRunner"
	add_child(floor_runner)
	# Множитель сложности к этому моменту уже выставлен: его пишет только
	# GameConfig.apply_to_arena, а она отработала в _build_arena.
	floor_runner.setup(arena, run_seed, GameConfig.difficulty_threat_mult)
	floor_runner.room_entered.connect(_on_room_entered)
	floor_runner.floor_started.connect(_on_floor_started)
	floor_runner.fight_started.connect(_on_fight_started)
	floor_runner.room_cleared.connect(_on_room_cleared)
	# 13b: floor_runner.reward_offered -> _show_upgrades; подсказка сундука и
	# люка (_chest_hint) - запросом к FloorRunner, как подсказка двери.


func _on_room_entered(_cell: Vector2i, from_side: int) -> void:
	_door_hint.visible = false
	# Подсказка по управлению возвращается в каждой новой комнате: между
	# забегами легко забыть, что напарника поднимают именно F.
	_hint_time = HINT_SECONDS
	_hint_box.modulate.a = 1.0
	_hint_box.visible = true
	if from_side >= 0:
		_snap_view_into_room()


## Камера игрока - вслед за телом, которое FloorRunner развернул в комнату.
##
## У игрока направление держит не тело, а камера: PlayerInput строит движение
## от её угла и при движении (или с поднятым щитом) выводит из него же
## intent_facing_yaw. Развернуть одно тело мало - следующий же кадр ввода
## вернул бы его к старому углу камеры.
func _snap_view_into_room() -> void:
	# Кадр движения запоминаем ДО разворота камеры: пока игрок держит те же
	# клавиши, он идёт туда же, куда шёл (см. PlayerInput.hold_move_frame).
	var controller := arena.gladiator.get_node_or_null("PlayerInput")
	if controller != null and controller.has_method("hold_move_frame"):
		controller.hold_move_frame()
	if _rig != null and _rig.has_method("snap_behind_target"):
		_rig.snap_behind_target()


func _on_floor_started(floor_number: int, room_count: int) -> void:
	_show_toast("Этаж %d · комнат: %d" % [floor_number, room_count])


func _on_fight_started(_cell: Vector2i, boss: bool) -> void:
	_show_toast("Логово босса — двери заперты" if boss
		else "Двери заперты — зачисти комнату")


func _on_room_cleared(_cell: Vector2i) -> void:
	# 13b: текст по типу комнаты - два запертых сундука, босс и люк вниз.
	_show_toast("Комната зачищена — двери открыты")


## Кадр этажа: переход через дверь делает FloorRunner.tick(), здесь -
## подсказка о ближайшей открытой двери. После перехода FloorRunner отдаёт
## «подсказки нет», и в кадре входа она гаснет, как и раньше.
func _update_room() -> void:
	floor_runner.tick()
	var d := floor_runner.door_hint_distance()
	_door_hint.visible = d >= 0.0
	if _door_hint.visible:
		_door_hint.text = "Дверь открыта — проход в соседнюю комнату   (%.0f м)" % d


# ------------------------------------------------------------------
# Улучшения
# ------------------------------------------------------------------

## 13b: вызывается по сигналу FloorRunner об открытом сундуке (обычный - три
## из LIST, запертый - три из RARE, босса - один из RARE). В 13a награды за
## волну больше нет, и вызывающего пока нет вовсе.
##
## Генератор - общий генератор забега (FloorRunner.rng): при заданном сиде
## награды повторяются вместе с этажом.
func _show_upgrades() -> void:
	for c in _upgrade_box.get_children():
		c.queue_free()

	var title := UITheme.title("Выбери награду", 28, UITheme.ACCENT, 0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_upgrade_box.add_child(title)
	_upgrade_box.add_child(_spacer(6))

	for u in Upgrades.roll(floor_runner.rng, 3):
		_upgrade_box.add_child(_upgrade_card(u))

	_upgrade_overlay.visible = true
	get_tree().paused = true
	_capture_mouse(false)
	Engine.time_scale = 1.0
	_stop_until_ms = 0


## Какой глиф показать на карточке награды. Иконка нужна не для красоты:
## названия вроде «Второе дыхание» и «Братство» ничего не говорят о том,
## что именно улучшается, а меч, щит и склянка говорят сразу.
const UPGRADE_ICONS := {
	"hp": "helmet", "sword_damage": "sword", "sword_speed": "sword",
	"shield_stamina": "shield", "shield_regen": "shield", "speed": "banner",
	"kick_stun": "skull", "reach": "sword", "potion": "potion",
	"revive": "helmet",
}


## Карточка награды.
##
## Содержимое лежит дочерними узлами поверх кнопки, а не в её тексте: две
## строки разного размера и цвета плюс иконка в Button.text не помещаются.
## Дочерние узлы игнорируют мышь, поэтому клик по-прежнему ловит кнопка.
func _upgrade_card(u: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(460, 68)
	b.process_mode = Node.PROCESS_MODE_ALWAYS
	b.pressed.connect(_on_upgrade_picked.bind(str(u["id"])))

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14.0
	row.offset_right = -14.0
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(row)

	var icon_name: String = UPGRADE_ICONS.get(str(u["id"]), "banner")
	var icon := UITheme.icon_rect(icon_name, 30, UITheme.ACCENT)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)

	var col := VBoxContainer.new()
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	col.add_child(UITheme.title(str(u["name"]), 19, UITheme.FG, 0))
	col.add_child(UITheme.label(str(u["desc"]), 13, UITheme.DIM, 0))
	return b


func _on_upgrade_picked(id: String) -> void:
	Upgrades.apply(id, arena.get_fighters(), arena)
	floor_runner.run_state().taken_upgrades.append(id)
	_upgrade_overlay.visible = false
	get_tree().paused = false
	_capture_mouse(true)
	var u := Upgrades.find(id)
	if not u.is_empty():
		_show_toast("Получено: " + str(u["name"]))


func _build_upgrade_overlay(layer: CanvasLayer) -> void:
	_upgrade_overlay = Control.new()
	_upgrade_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_upgrade_overlay.visible = false
	_upgrade_overlay.theme = UITheme.theme()
	_upgrade_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.add_child(_upgrade_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.03, 0.86)
	_upgrade_overlay.add_child(dim)

	_upgrade_box = VBoxContainer.new()
	_upgrade_box.set_anchors_preset(Control.PRESET_CENTER)
	_upgrade_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_upgrade_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_upgrade_box.add_theme_constant_override("separation", 12)
	_upgrade_overlay.add_child(_upgrade_box)


# ------------------------------------------------------------------
# Пауза и итоги
# ------------------------------------------------------------------

func _build_overlay(layer: CanvasLayer) -> void:
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	_overlay.theme = UITheme.theme()
	# Оверлей обязан жить на паузе, иначе кнопки перестанут нажиматься
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.add_child(_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.03, 0.82)
	_overlay.add_child(dim)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 10)
	_overlay.add_child(box)

	box.add_child(UITheme.icon_rect("emblem", 64, UITheme.ACCENT))

	_overlay_title = UITheme.title("", 38, UITheme.ACCENT, 0)
	_overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_overlay_title)

	_overlay_text = UITheme.label("", 14, UITheme.DIM, 0)
	_overlay_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_overlay_text)

	box.add_child(_spacer(14))

	box.add_child(_menu_button("Продолжить / Заново", _on_primary))
	box.add_child(_menu_button("В меню", _to_menu))


func _menu_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 42)
	b.add_theme_font_size_override("font_size", 16)
	# Оверлей живёт на паузе, значит и кнопки на нём тоже должны
	b.process_mode = Node.PROCESS_MODE_ALWAYS
	b.pressed.connect(handler)
	return b


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## Курсор захватывается только когда идёт бой: в паузе и в меню наград
## по кнопкам нужно попадать мышью.
func _capture_mouse(on: bool) -> void:
	if not on and is_instance_valid(arena) and is_instance_valid(arena.gladiator):
		var controller := arena.gladiator.get_node_or_null("PlayerInput")
		if controller != null:
			controller.clear_input()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _toggle_pause() -> void:
	var pausing := not get_tree().paused
	get_tree().paused = pausing
	_overlay.visible = pausing
	_capture_mouse(not pausing)
	if pausing:
		Engine.time_scale = 1.0
		_stop_until_ms = 0
	if pausing:
		var run := floor_runner.run_state()
		_overlay_title.text = "Пауза"
		_overlay_text.text = "Этаж %d · комнат зачищено %d · убито %d" % [
			run.floor_number, run.cleared.size(), arena.total_kills]


func _on_episode_ended(_reason: String) -> void:
	if _finished:
		return
	_finished = true
	# Сразу вместе с _finished: зачистка, пришедшая после конца забега (например
	# отложенный сигнал пустого набора), не должна попасть в итоги.
	floor_runner.halt()
	get_tree().paused = true
	_capture_mouse(false)
	Engine.time_scale = 1.0
	_stop_until_ms = 0

	var run := floor_runner.run_state()
	GameConfig.last_result = {
		"floor": run.floor_number,
		"rooms": run.cleared.size(),
		"kills": arena.total_kills,
		"time": _elapsed,
	}

	_overlay_title.text = "Арена пала"
	_overlay_text.text = "\n".join([
		"Продержались %d:%02d" % [int(_elapsed) / 60, int(_elapsed) % 60],
		"Этаж: %d" % run.floor_number,
		"Комнат зачищено: %d" % run.cleared.size(),
		"Убито зомби: %d" % arena.total_kills,
		"Улучшений собрано: %d" % run.taken_upgrades.size(),
		"Монет: %d" % run.coins,
	])
	_overlay.visible = true


func _on_primary() -> void:
	get_tree().paused = false
	if _finished:
		get_tree().reload_current_scene()
	else:
		_overlay.visible = false
		_capture_mouse(true)


func _to_menu() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	_capture_mouse(false)
	get_tree().change_scene_to_file(MENU_SCENE)

# ------------------------------------------------------------------
# Виджеты HUD
# ------------------------------------------------------------------

## Полоса с обоймой, сглаживанием и «призраком» потери.
##
## Призрак - светлый хвост, который остаётся на месте прежнего значения и
## догоняет полосу с задержкой. Он показывает не «сколько осталось», а
## «сколько только что сняли»: без него удар на 34 единицы и удар на 12
## выглядят одинаково - полоса просто оказывается короче.
class HudBar extends Control:
	var color: Color
	## Ниже этой доли полоса пульсирует. 0 - не пульсировать.
	var pulse_below: float = 0.0
	## 0 - показывать значение мгновенно, без сглаживания.
	var smooth_speed: float = 16.0
	var ghost_speed: float = 2.6
	var ghost_delay: float = 0.35

	var _ghost: ColorRect
	var _fill: ColorRect
	var _label: Label
	var _target: float = 1.0
	var _shown: float = 1.0
	var _ghost_v: float = 1.0
	var _ghost_wait: float = 0.0
	var _t: float = 0.0

	func _init(w: int, h: int, c: Color, with_label: bool) -> void:
		color = c
		custom_minimum_size = Vector2(w, h)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

		# Ширина задаётся якорем, а не размером в пикселях: полоса тогда
		# правильно тянется вместе с панелью на любом разрешении.
		var back := ColorRect.new()
		back.set_anchors_preset(Control.PRESET_FULL_RECT)
		back.color = Color(0.06, 0.05, 0.05, 0.92)
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(back)

		_ghost = ColorRect.new()
		_ghost.set_anchors_preset(Control.PRESET_LEFT_WIDE)
		_ghost.anchor_right = 1.0
		_ghost.offset_right = 0.0
		_ghost.color = c.lightened(0.45)
		_ghost.color.a = 0.55
		_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_ghost)

		_fill = ColorRect.new()
		_fill.set_anchors_preset(Control.PRESET_LEFT_WIDE)
		_fill.anchor_right = 1.0
		_fill.offset_right = 0.0
		_fill.color = c
		_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_fill)

		# Обойма ставится только если полоса выше суммы полей nine-slice.
		# Иначе кромка растянулась бы на всю плашку и закрыла заливку -
		# именно так полосы здоровья и оказались сплошь золотыми.
		if h >= UITheme.BAR_MIN_HEIGHT:
			var frame := Panel.new()
			frame.set_anchors_preset(Control.PRESET_FULL_RECT)
			frame.add_theme_stylebox_override("panel", UITheme.bar_frame_style())
			frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(frame)

		if with_label:
			_label = UITheme.label("", maxi(11, h - 8), UITheme.FG, 3)
			_label.set_anchors_preset(Control.PRESET_FULL_RECT)
			_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			add_child(_label)

	func set_ratio(r: float) -> void:
		r = clampf(r, 0.0, 1.0)
		if r < _target:
			_ghost_wait = ghost_delay
		_target = r
		if smooth_speed <= 0.0:
			_shown = r
			_ghost_v = r

	func set_text(s: String) -> void:
		if _label != null:
			_label.text = s

	func _process(delta: float) -> void:
		if smooth_speed > 0.0:
			_shown = lerpf(_shown, _target, 1.0 - exp(-smooth_speed * delta))
			if absf(_shown - _target) < 0.002:
				_shown = _target

		# Призрак только опускается. При лечении он обязан подпрыгнуть сразу,
		# иначе светлый хвост окажется НИЖЕ полосы и прочитается как урон.
		if _target >= _ghost_v:
			_ghost_v = _target
			_ghost_wait = 0.0
		elif _ghost_wait > 0.0:
			_ghost_wait -= delta
		else:
			_ghost_v = lerpf(_ghost_v, _shown, 1.0 - exp(-ghost_speed * delta))

		_fill.anchor_right = _shown
		_fill.offset_right = 0.0
		_ghost.anchor_right = maxf(_ghost_v, _shown)
		_ghost.offset_right = 0.0

		if pulse_below > 0.0 and _target > 0.0 and _target < pulse_below:
			_t += delta
			_fill.color = color.lightened(0.35 * (0.5 + 0.5 * sin(_t * 9.0)))
		else:
			_fill.color = color

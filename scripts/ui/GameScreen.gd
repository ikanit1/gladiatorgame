extends Node3D

## Игровая сцена: арена по настройкам из меню, HUD на двоих, пауза и итоги.
##
## Арена создаётся кодом, а не стоит в .tscn инстансом. Причина простая:
## Arena._ready() выполняется раньше, чем _ready() родителя, и настройки
## (кооператив, сложность) успели бы опоздать - арена уже собрала бы пул
## и запустила первую волну по значениям из .tscn.

const MENU_SCENE := "res://scenes/ui/MainMenu.tscn"

const BG := Color("#12141a")
const PANEL := Color("#1b1f27")
const FG := Color("#e6e9ef")
const DIM := Color("#8d95a5")
const ACCENT := Color("#d99a3c")

@export var arena_scene: PackedScene

var arena: Arena
var _elapsed: float = 0.0
var _finished: bool = false

@onready var _rig: SpringArm3D = $CameraRig

var _hud: Control
var _p_hp: ColorRect
var _p_st: ColorRect
var _p_label: Label
var _ally_box: Control
var _a_hp: ColorRect
var _a_label: Label
var _ally_labels: Array[Control] = []
var _info: Label
var _overlay: Control
var _overlay_title: Label
var _overlay_text: Label
var _upgrade_overlay: Control
var _upgrade_box: VBoxContainer
var _revive_back: ColorRect
var _revive_fill: ColorRect
var _revive_label: Label
var _toast: Label
var _toast_time: float = 0.0
var _rng := RandomNumberGenerator.new()
var _taken: Array[String] = []
var _room_index: int = 0
var _room_cfg: Dictionary = {}
var _exit_hint: Label

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
	_rng.randomize()
	_build_arena()
	_build_hud()
	# Первая комната генерируется ПОСЛЕ HUD: подсказка о выходе и всплывающее
	# сообщение уже должны существовать к моменту входа.
	_enter_room(1)
	_capture_mouse(true)
	set_process_input(true)


func _build_arena() -> void:
	if arena_scene == null:
		push_error("GameScreen: не задана arena_scene")
		return

	arena = arena_scene.instantiate()
	GameConfig.apply_to_arena(arena)   # обязательно ДО add_child
	add_child(arena)

	arena.episode_ended.connect(_on_episode_ended)
	arena.wave_cleared.connect(_on_wave_cleared)
	arena.fighter_downed.connect(_on_fighter_downed)
	arena.fighter_revived.connect(_on_fighter_revived)
	arena.room_cleared.connect(_on_room_cleared)
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

	_update_hud()
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
	layer.add_child(_hud)

	# Панели - только фон. Всё содержимое кладём прямо на _hud абсолютными
	# координатами: PanelContainer сжимает вложенные Control по минимальному
	# размеру и обрезает подписи.
	_hud.add_child(_panel(Vector2(16, 16), Vector2(300, 92)))
	_hud.add_child(_text("ГЛАДИАТОР", Vector2(28, 22), 11, DIM))
	_p_hp = _bar(Vector2(28, 42), Vector2(276, 20), Color("#c8352c"))
	_p_label = _text("", Vector2(36, 43), 13, FG)
	_hud.add_child(_p_label)
	_p_st = _bar(Vector2(28, 70), Vector2(276, 12), Color("#59a0d8"))
	_hud.add_child(_text("щит", Vector2(36, 68), 10, Color(1, 1, 1, 0.85)))

	_ally_box = _panel(Vector2(16, 120), Vector2(300, 70))
	_hud.add_child(_ally_box)
	var ally_caption := _text("НАПАРНИК · ИИ", Vector2(28, 126), 11, ACCENT)
	_hud.add_child(ally_caption)
	_ally_labels = [ally_caption]
	_a_hp = _bar(Vector2(28, 146), Vector2(276, 20), Color("#7a9e4b"))
	_a_label = _text("", Vector2(36, 147), 13, FG)
	_hud.add_child(_a_label)
	_ally_labels.append(_a_label)

	_info = _text("", Vector2(18, 206), 15, FG)
	_hud.add_child(_info)

	# Если политика напарника не подошла (например, обучена на старом наборе
	# наблюдений), он просто стоит столбом. Молча это выглядит как баг игры,
	# поэтому причину показываем прямо на экране.
	if arena != null and arena.ally != null and arena.ally_status.begins_with("политика ждёт"):
		var warn := _text("Напарник не активен: " + arena.ally_status,
			Vector2(18, 232), 13, Color("#d1584f"))
		_hud.add_child(warn)

	# Полоса подъёма - показывается, только когда есть кого поднимать
	_revive_back = ColorRect.new()
	_revive_back.size = Vector2(340, 26)
	_revive_back.color = Color(0.08, 0.07, 0.07, 0.85)
	_revive_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_revive_back.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_revive_back.position = Vector2(-170, -150)
	_hud.add_child(_revive_back)

	_revive_fill = ColorRect.new()
	_revive_fill.size = Vector2(0, 22)
	_revive_fill.position = Vector2(2, 2)
	_revive_fill.color = ACCENT
	_revive_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_revive_back.add_child(_revive_fill)

	_revive_label = _text("", Vector2(10, 4), 12, FG)
	_revive_back.add_child(_revive_label)
	_revive_back.visible = false

	_exit_hint = _text("", Vector2(0, 0), 16, Color("#5fd39a"))
	_exit_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_exit_hint.position = Vector2(-260, -104)
	_exit_hint.size = Vector2(520, 26)
	_exit_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_exit_hint.visible = false
	_hud.add_child(_exit_hint)

	_toast = _text("", Vector2(0, 0), 18, ACCENT)
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.position = Vector2(-220, 86)
	_toast.size = Vector2(440, 30)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	_hud.add_child(_toast)

	var hint := _text("WASD — движение · ЛКМ / Space — меч · ПКМ / Shift — щит · E — пинок · F — поднять · Esc — пауза", Vector2(0, 0), 12, DIM)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(18, -34)
	_hud.add_child(hint)

	_build_overlay(layer)
	_build_upgrade_overlay(layer)


func _panel(pos: Vector2, size: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.position = pos
	p.custom_minimum_size = size
	p.size = size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.05, 0.05, 0.06, 0.66)
	st.set_corner_radius_all(6)
	p.add_theme_stylebox_override("panel", st)
	return p


func _bar(pos: Vector2, size: Vector2, color: Color) -> ColorRect:
	var back := ColorRect.new()
	back.position = pos - Vector2(2, 2)
	back.size = size + Vector2(4, 4)
	back.color = Color(0.08, 0.07, 0.07, 0.9)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(back)

	var fill := ColorRect.new()
	fill.position = pos
	fill.size = size
	fill.color = color
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(fill)
	fill.set_meta("full_width", size.x)
	return fill


func _text(s: String, pos: Vector2, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = s
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _set_bar(bar: ColorRect, ratio: float) -> void:
	bar.size.x = bar.get_meta("full_width") * clampf(ratio, 0.0, 1.0)


func _update_hud() -> void:
	var g := arena.gladiator
	_set_bar(_p_hp, g.get_health_ratio() if g.is_alive() else 0.0)
	_set_bar(_p_st, g.get_block_stamina_ratio())
	_p_label.text = "%d / %d" % [roundi(g.health), roundi(g.max_health)] if g.is_alive() else "ПАЛ"

	if arena.ally != null:
		_ally_box.visible = true
		_set_bar(_a_hp, arena.ally.get_health_ratio() if arena.ally.is_alive() else 0.0)
		_a_hp.visible = true
		_a_label.text = "%d / %d" % [roundi(arena.ally.health), roundi(arena.ally.max_health)] \
			if arena.ally.is_alive() else "пал"
	else:
		_ally_box.visible = false
		_a_hp.visible = false
		_a_label.text = ""

	_info.text = "Комната %d      Волна %d/%d · всего %d      Убито %d      Зомби %d      %d:%02d" % [
		_room_index, arena.wave_index, arena.waves_in_room, arena.run_wave_index,
		arena.total_kills,
		arena.get_alive_count(), int(_elapsed) / 60, int(_elapsed) % 60]

	_update_revive_ui()
	_update_room()


func _update_revive_ui() -> void:
	var downed: Gladiator = null
	for f in arena.get_fighters():
		if f.is_downed():
			downed = f
			break

	if downed == null:
		_revive_back.visible = false
		return

	_revive_back.visible = true
	_revive_fill.size.x = 336.0 * arena.revive_progress
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
# Комнаты
# ------------------------------------------------------------------

## Здоровье переносится между комнатами долей, а не абсолютом: улучшение
## «+25 к максимуму» иначе выглядело бы как потеря, ведь после перехода
## полоса становилась бы короче относительно нового максимума.
func _enter_room(index: int) -> void:
	var carry := {}
	for f in arena.get_fighters():
		if f.is_alive():
			carry[f] = f.get_health_ratio()

	_room_index = index
	_room_cfg = RoomGenerator.generate(index, _rng)
	if index == 1:
		arena.apply_room(_room_cfg)
	else:
		arena.advance_to_room(_room_cfg)
	GameConfig.apply_difficulty_to_room(arena)

	for f in arena.get_fighters():
		if carry.has(f):
			# Небольшая передышка за пройденную комнату
			f.health = clampf(f.max_health * float(carry[f]) + 15.0, 1.0, f.max_health)

	_exit_hint.visible = false
	_show_toast(RoomGenerator.describe(_room_cfg))


func _on_room_cleared(_index: int) -> void:
	_show_toast("Комната зачищена — дверь открыта")


func _update_room() -> void:
	if not arena.exit_open:
		_exit_hint.visible = false
		return

	_exit_hint.visible = true
	var d := arena.gladiator.global_position.distance_to(arena.exit_position)
	_exit_hint.text = "Дверь открыта — пройди в соседнюю комнату   (%.0f м)" % d

	if arena.fighter_at_exit(arena.gladiator):
		_enter_room(_room_index + 1)


# ------------------------------------------------------------------
# Улучшения между волнами
# ------------------------------------------------------------------

func _on_wave_cleared(wave: int) -> void:
	if _finished or wave <= 0:
		return
	_show_upgrades()


func _show_upgrades() -> void:
	for c in _upgrade_box.get_children():
		c.queue_free()

	var title := Label.new()
	title.text = "Волна отбита — выбери награду"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", ACCENT)
	_upgrade_box.add_child(title)

	for u in Upgrades.roll(_rng, 3):
		_upgrade_box.add_child(_upgrade_card(u))

	_upgrade_overlay.visible = true
	get_tree().paused = true
	_capture_mouse(false)
	Engine.time_scale = 1.0
	_stop_until_ms = 0


func _upgrade_card(u: Dictionary) -> Button:
	var b := Button.new()
	b.text = str(u["name"]) + "\n" + str(u["desc"])
	b.custom_minimum_size = Vector2(440, 64)
	b.add_theme_font_size_override("font_size", 15)
	b.process_mode = Node.PROCESS_MODE_ALWAYS
	var st := StyleBoxFlat.new()
	st.bg_color = PANEL
	st.set_corner_radius_all(6)
	st.set_content_margin_all(10)
	b.add_theme_stylebox_override("normal", st)
	var hv := st.duplicate() as StyleBoxFlat
	hv.bg_color = Color("#2c3340")
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_color_override("font_color", FG)
	b.pressed.connect(_on_upgrade_picked.bind(str(u["id"])))
	return b


func _on_upgrade_picked(id: String) -> void:
	Upgrades.apply(id, arena.get_fighters(), arena)
	_taken.append(id)
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

	_overlay_title = Label.new()
	_overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_title.add_theme_font_size_override("font_size", 34)
	_overlay_title.add_theme_color_override("font_color", ACCENT)
	box.add_child(_overlay_title)

	_overlay_text = Label.new()
	_overlay_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_text.add_theme_font_size_override("font_size", 14)
	_overlay_text.add_theme_color_override("font_color", DIM)
	box.add_child(_overlay_text)

	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 14)
	box.add_child(sp)

	box.add_child(_menu_button("Продолжить / Заново", _on_primary))
	box.add_child(_menu_button("В меню", _to_menu))


func _menu_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 42)
	b.add_theme_font_size_override("font_size", 16)
	b.process_mode = Node.PROCESS_MODE_ALWAYS
	var st := StyleBoxFlat.new()
	st.bg_color = PANEL
	st.set_corner_radius_all(6)
	b.add_theme_stylebox_override("normal", st)
	var hv := st.duplicate() as StyleBoxFlat
	hv.bg_color = PANEL.lightened(0.15)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_color_override("font_color", FG)
	b.pressed.connect(handler)
	return b


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
		_overlay_title.text = "Пауза"
		_overlay_text.text = "Волна %d (всего %d), убито %d" % [
			arena.wave_index, arena.run_wave_index, arena.total_kills]


func _on_episode_ended(_reason: String) -> void:
	if _finished:
		return
	_finished = true
	get_tree().paused = true
	_capture_mouse(false)
	Engine.time_scale = 1.0
	_stop_until_ms = 0

	GameConfig.last_result = {
		"wave": arena.run_wave_index,
		"kills": arena.total_kills,
		"time": _elapsed,
	}

	_overlay_title.text = "Арена пала"
	_overlay_text.text = "\n".join([
		"Продержались %d:%02d" % [int(_elapsed) / 60, int(_elapsed) % 60],
		"Комнат пройдено: %d" % maxi(_room_index - 1, 0),
		"Волна %d (всего %d), убито зомби: %d" % [
			arena.wave_index, arena.run_wave_index, arena.total_kills],
		"Улучшений собрано: %d" % _taken.size(),
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

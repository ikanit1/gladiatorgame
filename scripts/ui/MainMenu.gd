extends Control

## Главное меню. Интерфейс собирается кодом, а не в .tscn: так вся раскладка
## и все подписи лежат в одном файле, который можно прочитать сверху вниз,
## а не собирать по кускам из дерева узлов.
##
## Оформление берётся из UITheme - палитра, рамки и кнопки общие с игровым
## экраном, чтобы меню и HUD не разъезжались при правках.

const GAME_SCENE := "res://scenes/Game.tscn"

var _menu_page: VBoxContainer
var _settings_page: Control
var _policy_option: OptionButton
var _policy_paths: Array[String] = []
var _coop_check: CheckButton
var _diff_option: OptionButton
var _volume_slider: HSlider
var _hint: Label
var _play_button: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.theme()
	_build()
	_load_into_ui()
	# Меню открывается и после выхода из боя, где курсор был захвачен
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_play_button.grab_focus()


## Меню и настройки - две страницы, а не одна растущая колонка.
##
## Раньше панель настроек раскрывалась под кнопками, и суммарная высота
## переваливала за экран: заголовок уезжал вверх, таблица управления - вниз.
## Раскладка, которая ломается при 648 пикселях по вертикали, неприемлема:
## это обычная высота окна на ноутбуке.
func _build() -> void:
	_build_background()

	_menu_page = VBoxContainer.new()
	_menu_page.set_anchors_preset(Control.PRESET_CENTER)
	_menu_page.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_menu_page.grow_vertical = Control.GROW_DIRECTION_BOTH
	_menu_page.custom_minimum_size = Vector2(460, 0)
	_menu_page.add_theme_constant_override("separation", 10)
	add_child(_menu_page)

	var emblem := UITheme.icon_rect("emblem", 120, UITheme.ACCENT)
	emblem.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_menu_page.add_child(emblem)

	var title := UITheme.title("AIFIGHT", 58, UITheme.ACCENT, 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_page.add_child(title)

	var sub := UITheme.label("арена гладиатора", 15, UITheme.DIM, 3)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_page.add_child(sub)

	_menu_page.add_child(_spacer(20))
	_play_button = _button("Играть", _on_play, true)
	_menu_page.add_child(_play_button)
	_menu_page.add_child(_button("Настройки", _on_toggle_settings))
	_menu_page.add_child(_button("Выход", _on_quit))

	_hint = UITheme.label("", 12, UITheme.DIM, 3)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_page.add_child(_spacer(8))
	_menu_page.add_child(_hint)

	_settings_page = _build_settings()
	_settings_page.visible = false
	add_child(_settings_page)


## Фон: арт арены плюс две затемняющие подложки.
##
## Одной сплошной пелены мало. Арт светлый по краям и тёмный в центре, поэтому
## сверху идёт общее приглушение, а под самой колонкой меню - вертикальный
## градиент: без него подписи вроде «арена гладиатора» тонули бы в песке.
func _build_background() -> void:
	var art := TextureRect.new()
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.texture = load(UITheme.MENU_BG) if ResourceLoader.exists(UITheme.MENU_BG) else null
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)

	if art.texture == null:
		art.queue_free()
		var flat := ColorRect.new()
		flat.set_anchors_preset(Control.PRESET_FULL_RECT)
		flat.color = UITheme.BG
		add_child(flat)
		return

	var scrim := ColorRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(UITheme.BG.r, UITheme.BG.g, UITheme.BG.b, 0.45)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	grad.colors = PackedColorArray([
		Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.62), Color(0, 0, 0, 0.0)])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0.5, 0.0)
	gt.fill_to = Vector2(0.5, 1.0)

	var band := TextureRect.new()
	band.set_anchors_preset(Control.PRESET_FULL_RECT)
	band.texture = gt
	band.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	band.stretch_mode = TextureRect.STRETCH_SCALE
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(band)


func _build_settings() -> Control:
	var page := Control.new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)

	# Ширина фиксированная, высота - весь экран минус поля. Панель поэтому
	# не может перерасти окно: длинный список уезжает в прокрутку внутри,
	# а не выталкивает заголовок за край экрана.
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -250.0
	panel.offset_right = 250.0
	panel.offset_top = 44.0
	panel.offset_bottom = -44.0
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.94))
	page.add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	panel.add_child(outer)

	var head := UITheme.title("НАСТРОЙКИ", 22, UITheme.ACCENT, 0)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 12)
	scroll.add_child(box)

	# --- Напарник ---
	_coop_check = CheckButton.new()
	_coop_check.text = "Играть с ИИ-напарником"
	_coop_check.add_theme_color_override("font_color", UITheme.FG)
	_coop_check.toggled.connect(_on_coop_toggled)
	box.add_child(_coop_check)

	box.add_child(_caption("Модель напарника"))
	_policy_option = OptionButton.new()
	_policy_option.item_selected.connect(_on_policy_selected)
	box.add_child(_policy_option)

	# --- Сложность ---
	box.add_child(_caption("Сложность"))
	_diff_option = OptionButton.new()
	for d in [GameConfig.Difficulty.EASY, GameConfig.Difficulty.NORMAL, GameConfig.Difficulty.HARD]:
		_diff_option.add_item(GameConfig.difficulty_name(d))
	_diff_option.item_selected.connect(_on_difficulty_selected)
	box.add_child(_diff_option)

	# --- Звук ---
	box.add_child(_caption("Громкость"))
	_volume_slider = HSlider.new()
	_volume_slider.min_value = 0.0
	_volume_slider.max_value = 1.0
	_volume_slider.step = 0.05
	_volume_slider.custom_minimum_size = Vector2(0, 24)
	_volume_slider.value_changed.connect(_on_volume_changed)
	box.add_child(_volume_slider)

	box.add_child(_spacer(4))
	box.add_child(_caption("Управление"))
	box.add_child(_controls_table())

	outer.add_child(_button("Назад", _on_toggle_settings))
	return page


## Раскладка управления таблицей, а не одной простынёй текста: клавиша и
## её действие выровнены в две колонки и читаются с одного взгляда.
func _controls_table() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)

	var rows := [
		["WASD", "движение относительно камеры"],
		["мышь", "обзор"],
		["ЛКМ / Space", "меч"],
		["ПКМ / Shift", "щит"],
		["E", "пинок"],
		["F", "поднять напарника"],
		["Esc", "пауза"],
	]
	for r in rows:
		var key := UITheme.label(r[0], 12, UITheme.ACCENT, 0)
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		key.custom_minimum_size = Vector2(96, 0)
		grid.add_child(key)
		grid.add_child(UITheme.label(r[1], 12, UITheme.DIM, 0))
	return grid


# ------------------------------------------------------------------
# Мелкие строители
# ------------------------------------------------------------------

func _button(text: String, handler: Callable, primary: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.add_theme_font_size_override("font_size", 18)
	if primary:
		UITheme.make_primary(b)
	b.pressed.connect(handler)
	return b


func _caption(text: String) -> Label:
	return UITheme.label(text, 12, UITheme.DIM, 0)


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


# ------------------------------------------------------------------
# Данные
# ------------------------------------------------------------------

func _load_into_ui() -> void:
	_coop_check.button_pressed = GameConfig.coop
	_diff_option.select(GameConfig.difficulty)
	_volume_slider.value = GameConfig.master_volume

	_policy_paths = GameConfig.available_policies()
	_policy_option.clear()
	if _policy_paths.is_empty():
		_policy_option.add_item("нет обученных моделей")
		_policy_option.disabled = true
	else:
		var expected := _expected_obs()
		for p in _policy_paths:
			var dim := PolicyRunner.peek_obs_dim(p)
			var label := p.get_file().trim_suffix(".policy")
			# Модель со старым набором наблюдений напарник запустить не сможет,
			# и без пометки это выглядит как «игра сломалась»
			if expected > 0 and dim > 0 and dim != expected:
				label += "  (устарела: %d ≠ %d)" % [dim, expected]
			_policy_option.add_item(label)
		var idx := _policy_paths.find(GameConfig.ally_policy)
		_policy_option.select(maxi(idx, 0))
		if idx < 0:
			GameConfig.ally_policy = _policy_paths[0]

	_update_hint()


## Сколько наблюдений отдаёт нынешняя игра.
##
## Формула живёт в самом GladiatorBrain: здесь раньше стояла её копия с
## числом 23, и после добавления признака типа врага копия разъехалась бы
## с оригиналом. Меню тогда молча одобрило бы политику, которую движок
## не примет.
func _expected_obs() -> int:
	var brain := GladiatorBrain.new()
	var n := GladiatorBrain.observation_size_for(brain.lidar_rays)
	brain.free()
	return n


func _update_hint() -> void:
	if _policy_paths.is_empty():
		_hint.text = ("Напарник недоступен: в models/ нет ни одной политики.\n"
			+ "Обучи агента в панели (training/dashboard.py) и выгрузи её\n"
			+ "командой: python tools/export_policy.py --experiment ИМЯ")
		return
	_hint.text = "Напарник: %s   ·   %s" % [
		GameConfig.ally_policy.get_file().trim_suffix(".policy"),
		GameConfig.difficulty_name()]


# ------------------------------------------------------------------
# Обработчики
# ------------------------------------------------------------------

func _on_play() -> void:
	GameConfig.save_settings()
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_toggle_settings() -> void:
	var open := not _settings_page.visible
	_settings_page.visible = open
	_menu_page.visible = not open
	if not open:
		_play_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	# Esc из настроек возвращает в меню, а не выходит из игры
	if _settings_page.visible and event.is_action_pressed("ui_cancel"):
		_on_toggle_settings()
		get_viewport().set_input_as_handled()


func _on_quit() -> void:
	GameConfig.save_settings()
	get_tree().quit()


func _on_coop_toggled(on: bool) -> void:
	GameConfig.coop = on
	_update_hint()


func _on_policy_selected(index: int) -> void:
	if index >= 0 and index < _policy_paths.size():
		GameConfig.ally_policy = _policy_paths[index]
		_update_hint()


func _on_difficulty_selected(index: int) -> void:
	GameConfig.difficulty = index
	_update_hint()


func _on_volume_changed(value: float) -> void:
	GameConfig.master_volume = value
	GameConfig.apply_volume()

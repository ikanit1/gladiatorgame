extends Control

## Главное меню. Интерфейс собирается кодом, а не в .tscn: так вся раскладка
## и все подписи лежат в одном файле, который можно прочитать сверху вниз,
## а не собирать по кускам из дерева узлов.

const GAME_SCENE := "res://scenes/Game.tscn"

const BG := Color("#12141a")
const PANEL := Color("#1b1f27")
const FG := Color("#e6e9ef")
const DIM := Color("#8d95a5")
const ACCENT := Color("#d99a3c")

var _settings_box: PanelContainer
var _policy_option: OptionButton
var _policy_paths: Array[String] = []
var _coop_check: CheckButton
var _diff_option: OptionButton
var _volume_slider: HSlider
var _hint: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_load_into_ui()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical = Control.GROW_DIRECTION_BOTH
	center.custom_minimum_size = Vector2(460, 0)
	center.add_theme_constant_override("separation", 10)
	add_child(center)

	var title := Label.new()
	title.text = "AIFIGHT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 54)
	title.add_theme_color_override("font_color", ACCENT)
	center.add_child(title)

	var sub := Label.new()
	sub.text = "арена гладиатора"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", DIM)
	center.add_child(sub)

	center.add_child(_spacer(18))
	center.add_child(_button("Играть", _on_play, true))
	center.add_child(_button("Настройки", _on_toggle_settings))
	center.add_child(_button("Выход", _on_quit))

	_settings_box = _build_settings()
	_settings_box.visible = false
	center.add_child(_settings_box)

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", DIM)
	center.add_child(_spacer(8))
	center.add_child(_hint)


func _build_settings() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	# --- Напарник ---
	_coop_check = CheckButton.new()
	_coop_check.text = "Играть с ИИ-напарником"
	_coop_check.add_theme_color_override("font_color", FG)
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

	var controls := Label.new()
	controls.text = "\n".join([
		"Управление:",
		"WASD — движение относительно камеры,   мышь — обзор",
		"ЛКМ / Space — меч,   E — пинок,   ПКМ / Shift — щит",
		"со щитом: тело смотрит по камере, W/S — шаг вперёд и назад",
		"F — поднять напарника,   Esc — пауза",
	])
	controls.add_theme_font_size_override("font_size", 12)
	controls.add_theme_color_override("font_color", DIM)
	box.add_child(_spacer(4))
	box.add_child(controls)

	return panel


# ------------------------------------------------------------------
# Мелкие строители
# ------------------------------------------------------------------

func _button(text: String, handler: Callable, primary: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.add_theme_font_size_override("font_size", 18)

	var normal := StyleBoxFlat.new()
	normal.bg_color = ACCENT if primary else PANEL
	normal.set_corner_radius_all(6)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = normal.bg_color.lightened(0.12)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_color_override("font_color", Color("#1a1a1a") if primary else FG)
	b.pressed.connect(handler)
	return b


func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", DIM)
	return l


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


## Сколько наблюдений отдаёт нынешняя игра. Считаем по той же формуле,
## что и GladiatorBrain, чтобы не поднимать ради этого целую арену.
func _expected_obs() -> int:
	var brain := GladiatorBrain.new()
	var n := brain.lidar_rays * 2 + 23
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
	_settings_box.visible = not _settings_box.visible


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

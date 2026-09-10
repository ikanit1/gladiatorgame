extends Node

## Снимки интерфейса для проверки оформления без ручного запуска игры:
## меню, настройки, боевой HUD с уроном, пауза и выбор награды.

const OUT := "res://tools/ui_preview/"

var _game: Node


func _ready() -> void:
	# Снимки нужны и на паузе, иначе оверлеи не поймать
	process_mode = Node.PROCESS_MODE_ALWAYS
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	var menu: Control = load("res://scenes/ui/MainMenu.tscn").instantiate()
	add_child(menu)
	await _settle(30)
	_shot("menu.png")

	# Настройки раскрываем напрямую: имитация клика мышью в снимке
	# ненадёжна, а состояние панели зависит только от этого вызова.
	if menu.has_method("_on_toggle_settings"):
		menu.call("_on_toggle_settings")
	await _settle(20)
	_shot("menu_settings.png")

	menu.queue_free()
	await _settle(5)

	# Напарник включён намеренно: вторая панель HUD появляется только с ним
	GameConfig.coop = true
	_game = load("res://scenes/Game.tscn").instantiate()
	add_child(_game)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _settle(120)

	_wound()
	await _settle(12)
	_shot("game_hud.png")

	if _game.has_method("_show_upgrades"):
		_game.call("_show_upgrades")
	await _settle(20)
	_shot("upgrades.png")
	if _game.has_method("_on_upgrade_picked"):
		_game.call("_on_upgrade_picked", "hp")
	await _settle(10)

	if _game.has_method("_toggle_pause"):
		_game.call("_toggle_pause")
	await _settle(20)
	_shot("pause.png")

	get_tree().quit()


## Раненое состояние: только так видно «призрак» потери на полосе игрока
## и полосы над теми зомби, кого успели задеть.
func _wound() -> void:
	var arena = _game.get("arena")
	if arena == null:
		return
	arena.gladiator.take_damage(52.0, arena.gladiator.global_position + Vector3.FORWARD)
	if arena.ally != null:
		arena.ally.take_damage(30.0, arena.ally.global_position + Vector3.FORWARD)
	var hurt := 0
	for z in arena.get_alive_zombies() if arena.has_method("get_alive_zombies") else []:
		z.take_damage(18.0, z.global_position + Vector3.FORWARD)
		hurt += 1
		if hurt >= 2:
			break


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _shot(name: String) -> void:
	var err := get_viewport().get_texture().get_image().save_png(OUT + name)
	print("снимок %s: %s" % [name, "ок" if err == OK else "ошибка %d" % err])

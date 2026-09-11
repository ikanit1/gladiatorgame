extends SceneTree

## Главное, что проверяем: редкий апгрейд меняет только те поля Gladiator,
## которые УЖЕ существуют. Новое поле означало бы новое наблюдение или новое
## действие, а обученная политика напарника этого не переживёт.

func _init() -> void:
	var r := TestReport.new("Upgrades")
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150

	r.ge(float(Upgrades.RARE.size()), 6.0, "редких апгрейдов хотя бы шесть")

	var ids := {}
	for u in Upgrades.LIST + Upgrades.RARE:
		r.check(u.has("id") and u.has("name") and u.has("desc"),
			"у апгрейда есть id, name и desc")
		r.check(not ids.has(u["id"]), "id %s не дублируется" % u.get("id", "?"))
		ids[u["id"]] = true

	# roll_rare отдаёт нужное число различных апгрейдов
	for i in range(200):
		var picked := Upgrades.roll_rare(rng, 3)
		r.eq(picked.size(), 3, "редких выдано три")
		var seen := {}
		for u in picked:
			r.check(not seen.has(u["id"]), "редкие в выдаче не повторяются")
			seen[u["id"]] = true

	# Применение редких к живому бойцу: поля обязаны измениться
	var scene: PackedScene = load("res://scenes/Gladiator.tscn")
	r.check(scene != null, "сцена гладиатора загружается")
	var g: Gladiator = scene.instantiate()

	var before := {
		"sword_max_targets": g.sword_max_targets,
		"sword_arc_deg": g.sword_arc_deg,
		"parry_window": g.parry_window,
		"block_stamina_hit_cost": g.block_stamina_hit_cost,
		"attack_playback_speed": g.attack_playback_speed,
		"max_health": g.max_health,
		"kick_knockback": g.kick_knockback,
	}

	for u in Upgrades.RARE:
		Upgrades.apply(str(u["id"]), [g], null)

	r.check(g.sword_max_targets > before["sword_max_targets"], "меч задевает больше целей")
	r.check(g.sword_arc_deg > before["sword_arc_deg"], "дуга меча шире")
	r.check(g.parry_window > before["parry_window"], "окно парирования шире")
	r.check(g.block_stamina_hit_cost < before["block_stamina_hit_cost"],
		"щит дешевле держит удар")
	r.check(g.attack_playback_speed > before["attack_playback_speed"], "атака быстрее")
	r.check(g.max_health > before["max_health"], "здоровья больше")
	r.check(g.kick_knockback > before["kick_knockback"], "пинок отбрасывает сильнее")

	g.free()
	r.finish(self)

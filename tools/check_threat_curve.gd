extends SceneTree

## Проверка формул сложности. Цифры взяты из спеки, таблица «что это значит
## в ударах» — оттуда же.

func _init() -> void:
	var r := TestReport.new("ThreatCurve")
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345

	# Глубина: 0.0 на входе в первый этаж, 5.0 у финального босса
	r.eq(ThreatCurve.threat(1, 0, 8), 0.0, "глубина на входе в первый этаж")
	r.eq(ThreatCurve.threat(5, 8, 8), 5.0, "глубина у финального босса")
	r.eq(ThreatCurve.threat(3, 4, 8), 2.5, "середина третьего этажа")
	# Деление на ноль: этаж без боевых комнат не должен ломать формулу
	r.eq(ThreatCurve.threat(2, 0, 0), 1.0, "этаж без боевых комнат")

	# Множители
	r.in_range(ThreatCurve.health_scale(0.0), 1.0, 1.0, "здоровье в начале")
	r.in_range(ThreatCurve.health_scale(5.0), 2.49, 2.51, "здоровье у финального босса")
	r.in_range(ThreatCurve.damage_scale(5.0), 2.09, 2.11, "урон у финального босса")
	r.in_range(ThreatCurve.speed_scale(5.0), 1.24, 1.26, "скорость у финального босса")
	r.in_range(ThreatCurve.cooldown_scale(5.0), 0.72, 0.73, "кулдаун у финального босса")
	# Кулдаун не должен уходить ниже предела даже при нелепой глубине
	r.ge(ThreatCurve.cooldown_scale(100.0), ThreatCurve.COOLDOWN_MIN, "предел кулдауна")

	# Ключевая точка баланса: зомби становится трёхударным к третьему этажу
	var hp_floor3: float = 45.0 * ThreatCurve.health_scale(ThreatCurve.threat(3, 0, 8))
	r.eq(ceili(hp_floor3 / 34.0), 3, "на третьем этаже зомби в три удара базовым мечом")
	r.eq(ceili(hp_floor3 / 43.0), 2, "с одной Заточкой снова в два удара")

	# Количество врагов в комнате — таблица из спеки
	var bounds := {1: [4, 6], 2: [5, 7], 3: [6, 8], 4: [7, 9], 5: [8, 10]}
	for floor_number in bounds.keys():
		var low: int = bounds[floor_number][0]
		var high: int = bounds[floor_number][1]
		var seen_low := false
		var seen_high := false
		for i in range(400):
			var n := ThreatCurve.enemy_count(floor_number, rng)
			r.in_range(float(n), float(low), float(high),
				"врагов на этаже %d в границах" % floor_number)
			if n == low:
				seen_low = true
			if n == high:
				seen_high = true
		r.check(seen_low and seen_high,
			"на этаже %d встречаются оба конца диапазона" % floor_number)

	# Состав врагов — таблица из спеки
	r.in_range(ThreatCurve.runner_chance(1), 0.15, 0.15, "бегуны на первом этаже")
	r.in_range(ThreatCurve.runner_chance(5), 0.35, 0.35, "бегуны на пятом этаже")
	r.in_range(ThreatCurve.brute_chance(1), 0.0, 0.0, "громил на первом этаже нет")
	r.in_range(ThreatCurve.brute_chance(2), 0.10, 0.10, "громилы со второго этажа")
	r.in_range(ThreatCurve.brute_chance(5), 0.30, 0.30, "громилы на пятом этаже")

	# pick_variant обязан укладываться в заявленные доли
	var counts := {Zombie.Variant.NORMAL: 0, Zombie.Variant.RUNNER: 0, Zombie.Variant.BRUTE: 0}
	for i in range(20000):
		counts[ThreatCurve.pick_variant(5, rng)] += 1
	r.in_range(float(counts[Zombie.Variant.BRUTE]) / 20000.0, 0.27, 0.33,
		"доля громил на пятом этаже")
	r.in_range(float(counts[Zombie.Variant.RUNNER]) / 20000.0, 0.32, 0.38,
		"доля бегунов на пятом этаже")

	r.finish(self)

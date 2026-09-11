extends SceneTree

func _init() -> void:
	var r := TestReport.new("RunState")
	var rng := RandomNumberGenerator.new()
	rng.seed = 31337

	var state := RunState.new()
	r.eq(state.floor_number, 1, "забег начинается на первом этаже")
	r.eq(state.coins, 0, "монет в начале нет")
	r.eq(state.keys, 1, "один ключ на старте")
	r.eq(state.bombs, 1, "одна бомба на старте")

	state.add_coins(7)
	r.eq(state.coins, 7, "монеты прибавились")
	r.check(state.spend_coins(5), "трата по средствам проходит")
	r.eq(state.coins, 2, "монеты списались")
	r.check(not state.spend_coins(99), "трата не по средствам не проходит")
	r.eq(state.coins, 2, "неудачная трата ничего не списала")

	r.check(state.use_key(), "ключ тратится")
	r.check(not state.use_key(), "второго ключа нет")

	var plan := FloorPlan.generate(3, rng)
	r.eq(state.cleared_combat_rooms(plan), 0, "в начале этажа зачищено ноль")

	var combat := plan.cells_of_type(FloorPlan.RoomType.COMBAT)
	r.ge(float(combat.size()), 1.0, "на этаже есть боевые комнаты")
	state.mark_cleared(combat[0])
	r.eq(state.cleared_combat_rooms(plan), 1, "зачищенная боевая комната сосчитана")

	# Сокровищница не боевая и в счёт глубины не идёт
	var treasure := plan.cells_of_type(FloorPlan.RoomType.TREASURE)
	state.mark_cleared(treasure[0])
	r.eq(state.cleared_combat_rooms(plan), 1, "сокровищница не считается боевой")

	r.check(state.is_cleared(combat[0]), "комната помечена зачищенной")
	r.check(not state.is_visited(combat[1] if combat.size() > 1 else Vector2i(99, 99)),
		"непосещённая комната не помечена")

	# Переход на следующий этаж обнуляет карту, но не кошелёк и не апгрейды
	state.add_coins(10)
	state.taken_upgrades.append("hp")
	state.next_floor()
	r.eq(state.floor_number, 2, "этаж сменился")
	r.eq(state.coins, 12, "монеты перенеслись")
	r.eq(state.taken_upgrades.size(), 1, "апгрейды перенеслись")
	r.eq(state.cleared.size(), 0, "карта зачищенного обнулилась")
	r.eq(state.visited.size(), 0, "карта посещённого обнулилась")

	r.finish(self)

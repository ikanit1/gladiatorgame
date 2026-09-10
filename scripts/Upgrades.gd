class_name Upgrades
extends RefCounted

## Улучшения, которые выдаются между волнами.
##
## Все они меняют ПАРАМЕТРЫ бойцов, а не набор наблюдений. Это принципиально:
## обученная политика видит нормализованные величины (доля здоровья, готовность
## меча), поэтому +25 к максимуму HP или -15% к кулдауну для неё прозрачны -
## переобучать напарника из-за апгрейдов не нужно.
##
## Улучшение применяется ко ВСЕЙ команде: разводить прокачку игрока и напарника
## значило бы, что половину набранного добра некому использовать.

const LIST := [
	{"id": "hp", "name": "Крепкая кость",
		"desc": "+25 к максимуму здоровья, лечит на столько же"},
	{"id": "sword_damage", "name": "Заточка",
		"desc": "+9 урона мечом"},
	{"id": "sword_speed", "name": "Лёгкая рука",
		"desc": "Меч бьёт на 18% чаще"},
	{"id": "shield_stamina", "name": "Окованный щит",
		"desc": "+35 к запасу щита"},
	{"id": "shield_regen", "name": "Второе дыхание",
		"desc": "Щит восстанавливается вдвое быстрее"},
	{"id": "speed", "name": "Лёгкий шаг",
		"desc": "+0.7 к скорости передвижения"},
	{"id": "kick_stun", "name": "Тяжёлый сапог",
		"desc": "Пинок оглушает на 1.2 секунды дольше"},
	{"id": "reach", "name": "Длинный клинок",
		"desc": "+0.4 к дальности меча"},
	{"id": "potion", "name": "Крепкое зелье",
		"desc": "Зелья лечат на 15 больше"},
	{"id": "revive", "name": "Братство",
		"desc": "Поднимать напарника вдвое быстрее"},
]


## Три случайных различных улучшения.
static func roll(rng: RandomNumberGenerator, count: int = 3) -> Array:
	var pool := LIST.duplicate()
	var out: Array = []
	for i in mini(count, pool.size()):
		var idx := rng.randi_range(0, pool.size() - 1)
		out.append(pool[idx])
		pool.remove_at(idx)
	return out


static func find(id: String) -> Dictionary:
	for u in LIST:
		if u["id"] == id:
			return u
	return {}


## Применяет улучшение к команде. Арена нужна для тех эффектов, что живут
## не в бойце (сила зелий, скорость подъёма).
static func apply(id: String, fighters: Array, arena: Arena) -> void:
	for f in fighters:
		if f == null:
			continue
		match id:
			"hp":
				f.max_health += 25.0
				# Лечим на ту же величину, иначе прибавка к максимуму
				# ощущается как понижение доли здоровья
				f.health = minf(f.max_health, f.health + 25.0)
			"sword_damage":
				f.sword_damage += 9.0
			"sword_speed":
				f.sword_cooldown = maxf(0.2, f.sword_cooldown * 0.82)
			"shield_stamina":
				f.block_stamina_max += 35.0
				f.block_stamina = f.block_stamina_max
			"shield_regen":
				f.block_stamina_regen *= 2.0
			"speed":
				f.move_speed += 0.7
			"kick_stun":
				f.kick_stun_time += 1.2
			"reach":
				f.sword_range += 0.4

	if arena == null:
		return
	match id:
		"potion":
			arena.potion_heal += 15.0
			arena.set_potion_heal(arena.potion_heal)
		"revive":
			arena.revive_duration = maxf(0.4, arena.revive_duration * 0.5)

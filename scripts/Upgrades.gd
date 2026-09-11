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


## Редкий пул: из запертых сундуков и сундука босса.
##
## Строго из УЖЕ существующих полей Gladiator. Новое поле означало бы новое
## наблюдение или новое действие, а политика напарника обучена на фиксированном
## векторе - она этого не переживёт. Поэтому здесь нет ни «двойного удара»,
## ни метательного оружия: это поведение, а не параметр.
const RARE := [
	{"id": "wide_swing", "name": "Широкий замах",
		"desc": "Меч задевает на 2 противника больше"},
	{"id": "long_arc", "name": "Размах",
		"desc": "+40° к дуге меча"},
	{"id": "read_attack", "name": "Чтение удара",
		"desc": "+0.3 с к окну парирования"},
	{"id": "tough_guard", "name": "Непробиваемый",
		"desc": "Щит вдвое дешевле гасит удар"},
	{"id": "fast_hands", "name": "Быстрые руки",
		"desc": "Анимация атаки на 30% быстрее"},
	{"id": "great_vigor", "name": "Бычье сердце",
		"desc": "+60 к максимуму здоровья, лечит на столько же"},
	{"id": "heavy_boot", "name": "Таранный пинок",
		"desc": "Пинок отбрасывает вдвое сильнее"},
]


## Несколько случайных различных улучшений из обычного пула.
static func roll(rng: RandomNumberGenerator, count: int = 3) -> Array:
	return _roll_from(LIST, rng, count)


## То же из редкого пула: запертые сундуки и сундук босса.
static func roll_rare(rng: RandomNumberGenerator, count: int = 3) -> Array:
	return _roll_from(RARE, rng, count)


static func _roll_from(source: Array, rng: RandomNumberGenerator, count: int) -> Array:
	var pool := source.duplicate()
	var out: Array = []
	for i in mini(count, pool.size()):
		var idx := rng.randi_range(0, pool.size() - 1)
		out.append(pool[idx])
		pool.remove_at(idx)
	return out


static func find(id: String) -> Dictionary:
	for u in LIST + RARE:
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
			"wide_swing":
				f.sword_max_targets += 2
			"long_arc":
				f.sword_arc_deg += 40.0
			"read_attack":
				f.parry_window += 0.3
			"tough_guard":
				f.block_stamina_hit_cost = maxf(2.0, f.block_stamina_hit_cost * 0.5)
			"fast_hands":
				f.attack_playback_speed = minf(4.0, f.attack_playback_speed * 1.3)
			"great_vigor":
				f.max_health += 60.0
				f.health = minf(f.max_health, f.health + 60.0)
			"heavy_boot":
				f.kick_knockback *= 2.0

	if arena == null:
		return
	match id:
		"potion":
			arena.potion_heal += 15.0
			arena.set_potion_heal(arena.potion_heal)
		"revive":
			arena.revive_duration = maxf(0.4, arena.revive_duration * 0.5)

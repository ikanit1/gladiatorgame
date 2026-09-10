class_name ThreatCurve
extends RefCounted

## Единственное место, где сложность превращается в числа.
##
## Раньше это жило в трёх местах: масштабы зомби в Arena с порогом
## run_wave_index > 10, состав врагов в Arena._pick_variant, количество и
## лимиты в RoomGenerator.generate. Порог «после десятой волны» и был главной
## причиной, по которой первые комнаты ломались об колено: до него все враги
## шли на базовых статах.
##
## Ни одного узла: формулы прогоняются тестом без поднятия игры.

const FLOOR_COUNT := 5

const HEALTH_PER_FLOOR := 0.30
const DAMAGE_PER_FLOOR := 0.22
const SPEED_PER_FLOOR := 0.05
const COOLDOWN_PER_FLOOR := 0.055
const COOLDOWN_MIN := 0.45

## Доли разновидностей по этажам, индекс = этаж - 1.
const RUNNER_CHANCE := [0.15, 0.20, 0.25, 0.30, 0.35]
const BRUTE_CHANCE := [0.00, 0.10, 0.16, 0.22, 0.30]

## Запертая комната тяжелее обычной на этом множителе.
const LOCKED_ROOM_ENEMY_MULT := 1.5


## Сквозная глубина забега: 0.0 на входе в первый этаж, 5.0 у финального босса.
## Считается от этажа и доли зачищенных боевых комнат, а не от счётчика волн.
static func threat(floor_number: int, cleared_rooms: int, total_rooms: int) -> float:
	var base := float(maxi(1, floor_number) - 1)
	if total_rooms <= 0:
		return base
	var progress := clampf(float(cleared_rooms) / float(total_rooms), 0.0, 1.0)
	return base + progress


## Порядок объявления этих четырёх функций намеренно совпадает с порядком
## аргументов Zombie.set_threat_scaling(health, speed, damage, cooldown).
## Если копировать функции «в порядке файла», легко переставить местами
## скорость и урон — оба множителя валидные числа, и тест такую перестановку
## не поймает.
static func health_scale(t: float) -> float:
	return 1.0 + HEALTH_PER_FLOOR * maxf(0.0, t)


static func speed_scale(t: float) -> float:
	return 1.0 + SPEED_PER_FLOOR * maxf(0.0, t)


static func damage_scale(t: float) -> float:
	return 1.0 + DAMAGE_PER_FLOOR * maxf(0.0, t)


static func cooldown_scale(t: float) -> float:
	return maxf(COOLDOWN_MIN, 1.0 - COOLDOWN_PER_FLOOR * maxf(0.0, t))


## Все враги комнаты живы одновременно, доспавна нет. Значение идёт и в
## Arena.max_alive, поэтому верхняя граница обязана быть меньше pool_size.
static func enemy_count(floor_number: int, rng: RandomNumberGenerator) -> int:
	return 3 + clampi(floor_number, 1, FLOOR_COUNT) + rng.randi_range(0, 2)


static func locked_room_enemy_count(floor_number: int, rng: RandomNumberGenerator) -> int:
	return int(ceil(float(enemy_count(floor_number, rng)) * LOCKED_ROOM_ENEMY_MULT))


static func runner_chance(floor_number: int) -> float:
	return RUNNER_CHANCE[clampi(floor_number, 1, FLOOR_COUNT) - 1]


static func brute_chance(floor_number: int) -> float:
	return BRUTE_CHANCE[clampi(floor_number, 1, FLOOR_COUNT) - 1]


static func pick_variant(floor_number: int, rng: RandomNumberGenerator) -> int:
	var brute := brute_chance(floor_number)
	var runner := runner_chance(floor_number)
	var roll := rng.randf()
	if roll < brute:
		return Zombie.Variant.BRUTE
	if roll < brute + runner:
		return Zombie.Variant.RUNNER
	return Zombie.Variant.NORMAL

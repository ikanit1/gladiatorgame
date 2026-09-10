# Этажи-сетка и сундуки: срез 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Заменить бесконечную цепочку комнат на этаж-сетку в духе The Binding of Isaac, где награды выдаются только из сундуков, а сложность считается от сквозной глубины забега.

**Architecture:** Этаж — это данные (`FloorPlan`, `ThreatCurve`: RefCounted, без узлов, тестируются headless). Физические комнаты строит `DungeonFloor` лениво, по мере входа. `Arena` остаётся «текущей комнатой» и про этажи с экономикой не знает: она получает готовый список врагов через `spawn_encounter`. Экономика живёт в `RunState`. Направление зависимостей одностороннее: `GameScreen` знает про всех, `Arena` — ни про что.

**Tech Stack:** Godot 4.6.3 (GDScript), headless-проверки через `--script` в `tools/`, обученная политика напарника `gladiator_team_v5` (её наблюдения и действия менять нельзя).

**Спека:** [2026-09-11-floors-chests-rewards-design.md](../specs/2026-09-11-floors-chests-rewards-design.md)

**Объём этого плана:** шаги 1–4 спеки — сетка этажа, переходы между комнатами, бой-за-комнату вместо волн, сундуки с апгрейдами, монеты. После этого плана в игру можно играть и мерить сложность. Ключи, бомбы, лавка, секретка, босс и миникарта — второй план.

---

## Как запускать проверки

Godot не в PATH. Полный путь к бинарю:

```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_threat_curve.gd
```

Проверки на чистой логике пишутся как `extends SceneTree` и запускаются через `--script` — сцена не нужна. Проверки, которым нужно дерево узлов, пишутся как `extends Node` с парным `.tscn` и запускаются так:

```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight res://tools/check_dungeon_floor.tscn
```

`quit(1)` внутри скрипта становится кодом возврата процесса — это проверено, на этом и строятся проверки.

После создания нового `.gd` Godot сам создаст рядом `.gd.uid`. Эти файлы **нужно коммитить** — в них идентификаторы, по которым сцены ссылаются на скрипты (см. `.gitignore`).

---

## Состав файлов

| Файл | Действие | Ответственность |
|---|---|---|
| `tools/TestReport.gd` | создать | Общий помощник для headless-проверок: `check`, `eq`, `ge`, `finish` с кодом возврата |
| `scripts/run/ThreatCurve.gd` | создать | Единственное место, где сложность превращается в числа |
| `scripts/run/FloorPlan.gd` | создать | Топология этажа: клетки, типы комнат, двери, расстояния |
| `scripts/run/RunState.gd` | создать | Монеты, апгрейды, посещённое и зачищенное |
| `scripts/run/DungeonFloor.gd` | создать | Ленивая постройка комнат по клеткам, переход через дверь |
| `scripts/run/Pickup.gd` | создать | Монета как подбираемый предмет (пул, по образцу `Potion`) |
| `scripts/run/Chest.gd` | создать | Сундук: вид, состояние, сигнал `opened` |
| `scenes/Pickup.tscn` | создать | Сцена монеты |
| `scenes/Chest.tscn` | создать | Сцена сундука |
| `scripts/RoomGenerator.gd` | править | Сужается до геометрии: фиксированный габарит 13×11, контур, тема |
| `scripts/DungeonRoom.gd` | править | До четырёх дверей с состояниями вместо «вход»/«выход» |
| `scripts/Arena.gd` | править | Флаг `encounter_driven` и метод `spawn_encounter`; волновой цикл для игры не используется |
| `scripts/Upgrades.gd` | править | Рядом с `LIST` появляется `RARE` |
| `scripts/ui/GameScreen.gd` | править | Склейка: `FloorPlan` → `DungeonFloor` → `Arena`; сундук вместо награды за волну; убраны утечки силы |
| `tools/check_threat_curve.gd` | создать | Проверка формул сложности |
| `tools/check_floor_plan.gd` | создать | 2000 планировок: босс, сокровищница, расстояние, границы |
| `tools/check_room_geometry.gd` | создать | Габарит 13×11 и центральные клетки сторон у всех контуров |
| `tools/check_dungeon_floor.gd` + `.tscn` | создать | Стыковка дверей соседних комнат в мировых координатах |
| `tools/check_run_state.gd` | создать | Экономика `RunState` |

---

### Task 1: Общий помощник для проверок

Сейчас каждый инструмент в `tools/` заводит свой `check(ok, message)` (см. `tools/check_combat_animation.gd:11`). Один помощник на все новые проверки убирает это дублирование и даёт честный код возврата.

**Files:**
- Create: `tools/TestReport.gd`

- [ ] **Step 1: Написать помощник**

```gdscript
class_name TestReport
extends RefCounted

## Помощник для headless-проверок в tools/.
##
## Код возврата обязателен: без него упавшая проверка выглядит как успешная,
## потому что Godot сам по себе завершается нулём даже после push_error.

var _suite: String = ""
var _checks: int = 0
var _failures: Array[String] = []


func _init(suite_name: String) -> void:
	_suite = suite_name


func check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(message)


func eq(actual: Variant, expected: Variant, message: String) -> void:
	check(actual == expected, "%s: получено %s, ожидалось %s" % [message, actual, expected])


func ge(actual: float, minimum: float, message: String) -> void:
	check(actual >= minimum, "%s: получено %s, ожидалось не меньше %s" % [message, actual, minimum])


func in_range(actual: float, low: float, high: float, message: String) -> void:
	check(actual >= low and actual <= high,
		"%s: получено %s, ожидался диапазон %s..%s" % [message, actual, low, high])


## Печатает итог и завершает процесс. Код 1, если хоть одна проверка упала.
func finish(tree: SceneTree) -> void:
	print("[%s] проверок: %d, упало: %d" % [_suite, _checks, _failures.size()])
	for f in _failures:
		print("  ПРОВАЛ: " + f)
	tree.quit(1 if not _failures.is_empty() else 0)
```

- [ ] **Step 2: Проверить, что помощник парсится и код возврата работает**

Создать временный файл `tools/_selftest.gd`:

```gdscript
extends SceneTree

func _init() -> void:
	var r := TestReport.new("самопроверка")
	r.eq(2 + 2, 4, "арифметика")
	r.eq(2 + 2, 5, "должно упасть")
	r.finish(self)
```

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/_selftest.gd; echo "код возврата = $?"
```
Expected: вывод содержит `проверок: 2, упало: 1` и `ПРОВАЛ: должно упасть`, код возврата = `1`.

- [ ] **Step 3: Удалить временный файл**

```bash
rm -f tools/_selftest.gd tools/_selftest.gd.uid
```

- [ ] **Step 4: Commit**

```bash
git add tools/TestReport.gd tools/TestReport.gd.uid
git commit -m "$(cat <<'EOF'
Помощник TestReport для headless-проверок

Код возврата обязателен: без него упавшая проверка выглядит успешной,
потому что Godot завершается нулём даже после push_error.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: ThreatCurve — все формулы сложности в одном файле

Сейчас сложность размазана: масштабы зомби в `Arena.gd:811-827` с порогом `run_wave_index > 10`, состав врагов в `Arena._pick_variant`, количество и лимиты в `RoomGenerator.generate`. Собираем в один RefCounted без узлов, чтобы формулы можно было прогнать тестом.

**Files:**
- Create: `scripts/run/ThreatCurve.gd`
- Create: `tools/check_threat_curve.gd`

- [ ] **Step 1: Написать падающую проверку**

`tools/check_threat_curve.gd`:

```gdscript
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
```

- [ ] **Step 2: Запустить проверку и убедиться, что она падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_threat_curve.gd; echo "код возврата = $?"
```
Expected: ошибка парсинга вида `Identifier "ThreatCurve" not declared in the current scope`, код возврата не 0.

- [ ] **Step 3: Написать ThreatCurve**

`scripts/run/ThreatCurve.gd`:

```gdscript
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


static func health_scale(t: float) -> float:
	return 1.0 + HEALTH_PER_FLOOR * maxf(0.0, t)


static func damage_scale(t: float) -> float:
	return 1.0 + DAMAGE_PER_FLOOR * maxf(0.0, t)


static func speed_scale(t: float) -> float:
	return 1.0 + SPEED_PER_FLOOR * maxf(0.0, t)


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
```

- [ ] **Step 4: Запустить проверку и убедиться, что она проходит**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_threat_curve.gd; echo "код возврата = $?"
```
Expected: `[ThreatCurve] проверок: ..., упало: 0`, код возврата = `0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/ThreatCurve.gd scripts/run/ThreatCurve.gd.uid tools/check_threat_curve.gd tools/check_threat_curve.gd.uid
git commit -m "$(cat <<'EOF'
ThreatCurve: сложность считается от глубины забега, а не от номера волны

Порог run_wave_index > 10 был главной причиной, почему первые комнаты
ломались об колено: до него все враги шли на базовых статах. Теперь
сложность считается от (этаж, доля зачищенных комнат) с первого же боя.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: FloorPlan — рост планировки

Алгоритм Isaac: от старта растим «щупальца», клетку не ставим, если у неё больше одного уже готового соседа. Без этой проверки комнаты слипаются в блоб вместо узнаваемой ветвистой карты.

**Files:**
- Create: `scripts/run/FloorPlan.gd`
- Create: `tools/check_floor_plan.gd`

- [ ] **Step 1: Написать падающую проверку роста**

`tools/check_floor_plan.gd`:

```gdscript
extends SceneTree

## 2000 планировок на этаж. Проверки — приёмочные условия из спеки.

func _init() -> void:
	var r := TestReport.new("FloorPlan")
	var rng := RandomNumberGenerator.new()
	rng.seed = 777

	for floor_number in range(1, ThreatCurve.FLOOR_COUNT + 1):
		var min_rooms := 99
		var max_rooms := 0
		for i in range(2000):
			var plan := FloorPlan.generate(floor_number, rng)

			min_rooms = mini(min_rooms, plan.room_count())
			max_rooms = maxi(max_rooms, plan.room_count())

			# Связность: каждая комната должна иметь расстояние от старта
			for cell in plan.rooms.keys():
				if cell == plan.secret_cell:
					continue   # секретка вне обычного обхода
				r.check(plan.distances.has(cell),
					"комната %s недостижима от старта (этаж %d)" % [cell, floor_number])

			# Старт на месте и он один
			r.check(plan.has_room(FloorPlan.START_CELL), "стартовая клетка существует")
			r.eq(plan.type_count(FloorPlan.RoomType.START), 1, "ровно один старт")

			# В сетку вписались
			for cell in plan.rooms.keys():
				r.check(cell.x >= 0 and cell.x < FloorPlan.GRID_W
					and cell.y >= 0 and cell.y < FloorPlan.GRID_H,
					"клетка %s вне сетки" % cell)

		r.in_range(float(min_rooms), 8.0, 30.0,
			"минимум комнат на этаже %d в разумных границах" % floor_number)
		r.in_range(float(max_rooms), 8.0, 30.0,
			"максимум комнат на этаже %d в разумных границах" % floor_number)
		print("  этаж %d: комнат %d..%d" % [floor_number, min_rooms, max_rooms])

	r.finish(self)
```

- [ ] **Step 2: Запустить и убедиться, что падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_floor_plan.gd; echo "код возврата = $?"
```
Expected: `Identifier "FloorPlan" not declared in the current scope`, код возврата не 0.

- [ ] **Step 3: Написать FloorPlan с ростом и обходом**

`scripts/run/FloorPlan.gd`:

```gdscript
class_name FloorPlan
extends RefCounted

## Топология этажа: какие клетки заняты, что в них и где двери.
##
## Ни одного узла намеренно: планировку можно прогнать две тысячи раз в тесте
## и посмотреть на распределение, не поднимая игру. Физические комнаты по этим
## данным строит DungeonFloor.

enum RoomType { START, COMBAT, TREASURE, SHOP, LOCKED, SECRET, BOSS }

## Состояние двери живёт здесь, а не в DungeonRoom: FloorPlan не зависит ни от
## одного узла, поэтому зависимость DungeonRoom -> FloorPlan односторонняя.
enum DoorState { OPEN, LOCKED_BY_FIGHT, LOCKED_BY_KEY, CRACKED_WALL }

const GRID_W := 9
const GRID_H := 8
const START_CELL := Vector2i(4, 3)

## Четыре стороны в том же порядке, что и в DungeonRoom:
## 0 - север (-z), 1 - юг (+z), 2 - восток (+x), 3 - запад (-x).
const SIDE_OFFSETS := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0)]

var floor_number: int = 1
var rooms: Dictionary = {}        ## Vector2i -> Dictionary со спецификацией комнаты
var distances: Dictionary = {}    ## Vector2i -> int, шагов от старта
var boss_cell: Vector2i = Vector2i(-1, -1)
var secret_cell: Vector2i = Vector2i(-1, -1)


static func generate(floor_number: int, rng: RandomNumberGenerator) -> FloorPlan:
	var plan := FloorPlan.new()
	plan.floor_number = maxi(1, floor_number)
	plan._grow(rng)
	plan._measure_distances()
	return plan


func has_room(cell: Vector2i) -> bool:
	return rooms.has(cell)


func spec(cell: Vector2i) -> Dictionary:
	return rooms.get(cell, {})


func room_count() -> int:
	return rooms.size()


func type_count(room_type: int) -> int:
	var n := 0
	for cell in rooms.keys():
		if int(rooms[cell]["type"]) == room_type:
			n += 1
	return n


func cells_of_type(room_type: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell in rooms.keys():
		if int(rooms[cell]["type"]) == room_type:
			out.append(cell)
	return out


func combat_room_count() -> int:
	return type_count(RoomType.COMBAT) + type_count(RoomType.LOCKED)


## Соседние клетки, в которых есть комната. Секретка исключена: в неё нет
## обычной двери, туда попадают через треснувшую стену.
func neighbours(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for offset in SIDE_OFFSETS:
		var n: Vector2i = cell + offset
		if rooms.has(n) and n != secret_cell and cell != secret_cell:
			out.append(n)
	return out


static func side_between(from_cell: Vector2i, to_cell: Vector2i) -> int:
	var delta := to_cell - from_cell
	for side in range(SIDE_OFFSETS.size()):
		if SIDE_OFFSETS[side] == delta:
			return side
	return -1


static func opposite_side(side: int) -> int:
	match side:
		0: return 1
		1: return 0
		2: return 3
		_: return 2


func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < GRID_W and cell.y >= 0 and cell.y < GRID_H


func _occupied_neighbour_count(cell: Vector2i) -> int:
	var n := 0
	for offset in SIDE_OFFSETS:
		if rooms.has(cell + offset):
			n += 1
	return n


func _target_room_count(rng: RandomNumberGenerator) -> int:
	return 7 + roundi(float(floor_number) * 1.8) + rng.randi_range(0, 1)


## Классический рост Isaac. Проверка «у соседа не больше одного занятого
## соседа» - главное, что даёт ветвистую карту с тупиками вместо слипшегося
## блоба: без неё комнаты заполняют сетку плотным пятном.
func _grow(rng: RandomNumberGenerator) -> void:
	rooms.clear()
	_put(START_CELL, RoomType.START)

	var target := _target_room_count(rng)
	var queue: Array[Vector2i] = [START_CELL]
	var guard := 0

	while rooms.size() < target and guard < 400:
		guard += 1
		var next: Array[Vector2i] = []
		for cell in queue:
			for offset in SIDE_OFFSETS:
				if rooms.size() >= target:
					break
				var n: Vector2i = cell + offset
				if not _in_bounds(n) or rooms.has(n):
					continue
				if _occupied_neighbour_count(n) > 1:
					continue
				if rng.randf() < 0.5:
					continue
				_put(n, RoomType.COMBAT)
				next.append(n)
		if next.is_empty():
			# Проход не дал ничего - перезапускаем волну от всех комнат,
			# иначе рост встанет на планировке меньше целевой.
			queue.clear()
			for cell in rooms.keys():
				queue.append(cell)
		else:
			queue = next


func _put(cell: Vector2i, room_type: int) -> void:
	rooms[cell] = {"cell": cell, "type": room_type}


func _measure_distances() -> void:
	distances.clear()
	distances[START_CELL] = 0
	var frontier: Array[Vector2i] = [START_CELL]
	while not frontier.is_empty():
		var next: Array[Vector2i] = []
		for cell in frontier:
			for offset in SIDE_OFFSETS:
				var n: Vector2i = cell + offset
				if rooms.has(n) and not distances.has(n):
					distances[n] = int(distances[cell]) + 1
					next.append(n)
		frontier = next
```

- [ ] **Step 4: Запустить и убедиться, что проходит**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_floor_plan.gd; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`, и в выводе строки вида `этаж 1: комнат 10..11`, `этаж 5: комнат 17..19`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/FloorPlan.gd scripts/run/FloorPlan.gd.uid tools/check_floor_plan.gd tools/check_floor_plan.gd.uid
git commit -m "$(cat <<'EOF'
FloorPlan: рост планировки этажа по алгоритму Isaac

Проверка "у соседа не больше одного занятого соседа" - главное, что даёт
ветвистую карту с тупиками вместо слипшегося пятна.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: FloorPlan — спец-комнаты, расстояние до босса, двери

Два ограничения из спеки, оба найдены прогоном генератора: `dist(boss) >= 4` и фоллбэк, когда тупиков меньше, чем спец-комнат. Без первого босс в 39% случаев оказывается в трёх шагах от старта, и этаж пробегается мимо сокровищницы.

**Files:**
- Modify: `scripts/run/FloorPlan.gd`
- Modify: `tools/check_floor_plan.gd`

- [ ] **Step 1: Дописать падающие проверки**

В `tools/check_floor_plan.gd` заменить тело цикла `for i in range(2000):` — добавить после проверок сетки, перед закрытием цикла:

```gdscript
			# Спец-комнаты обязаны быть на каждом этаже
			r.eq(plan.type_count(FloorPlan.RoomType.BOSS), 1,
				"ровно одна комната босса (этаж %d)" % floor_number)
			r.eq(plan.type_count(FloorPlan.RoomType.TREASURE), 1,
				"ровно одна сокровищница (этаж %d)" % floor_number)
			r.eq(plan.type_count(FloorPlan.RoomType.SECRET), 1,
				"ровно одна секретка (этаж %d)" % floor_number)
			if floor_number >= 2:
				r.eq(plan.type_count(FloorPlan.RoomType.SHOP), 1,
					"ровно одна лавка (этаж %d)" % floor_number)
			else:
				r.eq(plan.type_count(FloorPlan.RoomType.SHOP), 0,
					"на первом этаже лавки нет")

			# Главное ограничение: босс не ближе четырёх шагов от старта
			r.ge(float(int(plan.distances.get(plan.boss_cell, 0))),
				float(FloorPlan.MIN_BOSS_DISTANCE),
				"босс не ближе %d шагов (этаж %d)" % [FloorPlan.MIN_BOSS_DISTANCE, floor_number])

			# Двери: у каждой пары соседей дверь с обеих сторон и согласованная
			for cell in plan.rooms.keys():
				var doors := plan.doors_of(cell)
				for side in doors.keys():
					var other: Vector2i = cell + FloorPlan.SIDE_OFFSETS[side]
					r.check(plan.has_room(other),
						"дверь %s на сторону %d ведёт в пустоту" % [cell, side])
					var back := plan.doors_of(other)
					var back_side := FloorPlan.opposite_side(side)
					r.check(back.has(back_side),
						"у соседа %s нет ответной двери" % other)
					if back.has(back_side):
						r.eq(back[back_side], doors[side],
							"состояния двери %s<->%s расходятся" % [cell, other])

			# Секретка соседствует хотя бы с одной обычной комнатой
			var secret_links := 0
			for offset in FloorPlan.SIDE_OFFSETS:
				if plan.has_room(plan.secret_cell + offset):
					secret_links += 1
			r.ge(float(secret_links), 1.0, "секретка примыкает к комнате")
```

Также добавить в конец файла, перед `r.finish(self)`, сбор статистики по расстоянию — она пригодится при калибровке:

```gdscript
	var hist := {}
	for i in range(2000):
		var plan := FloorPlan.generate(1, rng)
		var d := int(plan.distances.get(plan.boss_cell, 0))
		hist[d] = int(hist.get(d, 0)) + 1
	var keys := hist.keys()
	keys.sort()
	var parts: Array[String] = []
	for d in keys:
		parts.append("%d шагов: %d" % [d, hist[d]])
	print("  распределение расстояния до босса на первом этаже — " + ", ".join(parts))
```

- [ ] **Step 2: Запустить и убедиться, что падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_floor_plan.gd; echo "код возврата = $?"
```
Expected: ошибка парсинга об отсутствии `MIN_BOSS_DISTANCE` или `doors_of`, код возврата не 0.

- [ ] **Step 3: Дописать FloorPlan**

В `scripts/run/FloorPlan.gd` добавить константы рядом с `START_CELL`:

```gdscript
## Ограничение найдено прогоном генератора: без него босс оказывался в трёх
## шагах от старта в 39% планировок первого этажа, и этаж пробегался за три
## комнаты мимо сокровищницы - ровно та болезнь, от которой лечимся.
const MIN_BOSS_DISTANCE := 4
const MAX_ATTEMPTS := 20

## Шанс, что на этаже появится запертая комната (со второго этажа).
const LOCKED_ROOM_CHANCE := 0.7
```

Заменить `generate` на версию с повторами:

```gdscript
static func generate(floor_number: int, rng: RandomNumberGenerator) -> FloorPlan:
	var plan: FloorPlan = null
	for attempt in range(MAX_ATTEMPTS):
		plan = FloorPlan.new()
		plan.floor_number = maxi(1, floor_number)
		plan._grow(rng)
		plan._measure_distances()
		plan._assign_special_rooms(rng)
		plan._place_secret(rng)
		plan._build_doors()
		if int(plan.distances.get(plan.boss_cell, 0)) >= MIN_BOSS_DISTANCE:
			return plan
	# Двадцать попыток не дали нужного расстояния - отдаём последнюю.
	# Планировка валидна, просто короче желаемого.
	return plan
```

Добавить в конец файла:

```gdscript
## Самый далёкий тупик - босс, ближние тупики раздаются спец-комнатам.
## Тупик = комната с ровно одним занятым соседом, кроме старта.
func _assign_special_rooms(rng: RandomNumberGenerator) -> void:
	var dead_ends: Array[Vector2i] = []
	for cell in rooms.keys():
		if cell == START_CELL:
			continue
		if _occupied_neighbour_count(cell) == 1:
			dead_ends.append(cell)

	dead_ends.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return int(distances.get(a, 0)) > int(distances.get(b, 0)))

	if dead_ends.is_empty():
		# Вырожденный случай: тупиков нет вообще. Берём самую далёкую комнату.
		boss_cell = _farthest_cell()
	else:
		boss_cell = dead_ends.pop_front()
	rooms[boss_cell]["type"] = RoomType.BOSS

	var wanted: Array[int] = [RoomType.TREASURE]
	if floor_number >= 2:
		wanted.append(RoomType.SHOP)
	if floor_number >= 2 and rng.randf() < LOCKED_ROOM_CHANCE:
		wanted.append(RoomType.LOCKED)

	# Ближние тупики - спец-комнатам: до сокровищницы должно быть проще
	# добраться, чем до босса.
	dead_ends.reverse()
	for room_type in wanted:
		var cell := dead_ends.pop_front() if not dead_ends.is_empty() else _append_dead_end()
		if cell == Vector2i(-1, -1):
			continue
		rooms[cell]["type"] = room_type


func _farthest_cell() -> Vector2i:
	var best := START_CELL
	var best_d := -1
	for cell in rooms.keys():
		var d := int(distances.get(cell, -1))
		if d > best_d:
			best_d = d
			best = cell
	return best


## Фоллбэк: тупиков не хватило на все спец-комнаты. Пристраиваем новую клетку
## к любой существующей так, чтобы у новой был ровно один сосед.
func _append_dead_end() -> Vector2i:
	for cell in rooms.keys():
		for offset in SIDE_OFFSETS:
			var n: Vector2i = cell + offset
			if not _in_bounds(n) or rooms.has(n):
				continue
			if _occupied_neighbour_count(n) != 1:
				continue
			_put(n, RoomType.COMBAT)
			distances[n] = int(distances.get(cell, 0)) + 1
			return n
	return Vector2i(-1, -1)


## Секретка - пустая клетка с наибольшим числом занятых соседей, как в Isaac.
## В неё не ведёт обычная дверь: вход через треснувшую стену.
func _place_secret(rng: RandomNumberGenerator) -> void:
	var best := Vector2i(-1, -1)
	var best_n := 1
	var fallback := Vector2i(-1, -1)
	for y in range(GRID_H):
		for x in range(GRID_W):
			var cell := Vector2i(x, y)
			if rooms.has(cell):
				continue
			var n := _occupied_neighbour_count(cell)
			if n >= 1 and fallback == Vector2i(-1, -1):
				fallback = cell
			if n > best_n or (n == best_n and n > 1 and rng.randf() < 0.3):
				best_n = n
				best = cell
	# Фоллбэк: у прямой, не загибающейся планировки может не оказаться пустой
	# клетки с двумя занятыми соседями. Тогда годится любая с одним - секретка
	# обязана быть на каждом этаже, это приёмочное условие.
	if best == Vector2i(-1, -1):
		best = fallback
	if best == Vector2i(-1, -1):
		return
	_put(best, RoomType.SECRET)
	secret_cell = best


## Двери строятся симметрично: каждая пара соседей получает по двери с обеих
## сторон с одинаковым состоянием. Иначе игрок может войти в комнату и не
## выйти обратно.
func _build_doors() -> void:
	for cell in rooms.keys():
		rooms[cell]["doors"] = {}

	for cell in rooms.keys():
		for side in range(SIDE_OFFSETS.size()):
			var other: Vector2i = cell + SIDE_OFFSETS[side]
			if not rooms.has(other):
				continue
			var state := _door_state_between(cell, other)
			rooms[cell]["doors"][side] = state
			rooms[other]["doors"][opposite_side(side)] = state


func _door_state_between(a: Vector2i, b: Vector2i) -> int:
	var type_a := int(rooms[a]["type"])
	var type_b := int(rooms[b]["type"])
	if type_a == RoomType.SECRET or type_b == RoomType.SECRET:
		return DoorState.CRACKED_WALL
	if type_a == RoomType.LOCKED or type_b == RoomType.LOCKED:
		return DoorState.LOCKED_BY_KEY
	return DoorState.OPEN


func doors_of(cell: Vector2i) -> Dictionary:
	return rooms.get(cell, {}).get("doors", {})
```

- [ ] **Step 4: Запустить и убедиться, что проходит**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_floor_plan.gd; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`, и строка с распределением, где случаев «3 шагов» нет вообще — все планировки отобраны по `dist >= 4`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/FloorPlan.gd tools/check_floor_plan.gd
git commit -m "$(cat <<'EOF'
FloorPlan: спец-комнаты, порог расстояния до босса и симметричные двери

Порог dist(boss) >= 4 найден прогоном: без него босс оказывался в трёх
шагах от старта в 39% планировок первого этажа, и этаж пробегался мимо
сокровищницы. Двери строятся парой с обеих сторон - иначе можно войти в
комнату и не выйти.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: RoomGenerator сужается до геометрии

Сейчас файл делает две несвязанные вещи: контур комнаты и баланс (`waves`, `first_wave`, `max_alive`, `runner_from`, `brute_from`, `potion_interval`). Баланс уехал в `ThreatCurve`, здесь остаётся геометрия. Габарит становится фиксированным — иначе комнаты не сложатся в сетку.

**Files:**
- Modify: `scripts/RoomGenerator.gd`
- Create: `tools/check_room_geometry.gd`

- [ ] **Step 1: Написать падающую проверку геометрии**

`tools/check_room_geometry.gd`:

```gdscript
extends SceneTree

## Фиксированный габарит - условие, без которого комнаты не складываются в
## сетку. Центральные клетки сторон обязаны существовать у ЛЮБОГО контура:
## именно через них проходят двери.

func _init() -> void:
	var r := TestReport.new("RoomGenerator")
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242

	r.eq(RoomGenerator.GRID_W, 13, "ширина в клетках")
	r.eq(RoomGenerator.GRID_D, 11, "глубина в клетках")
	r.in_range(RoomGenerator.ROOM_WIDTH, 26.0, 26.0, "ширина в метрах")
	r.in_range(RoomGenerator.ROOM_DEPTH, 22.0, 22.0, "глубина в метрах")

	var hx := RoomGenerator.GRID_W / 2
	var hz := RoomGenerator.GRID_D / 2

	for shape in RoomGenerator.SHAPES:
		var cfg := {"shape": shape, "grid_w": RoomGenerator.GRID_W, "grid_d": RoomGenerator.GRID_D}
		var cells: Array[Vector2i] = RoomGenerator.cells_for(cfg)
		r.check(not cells.is_empty(), "контур %s непустой" % shape)

		var min_cell := cells[0]
		var max_cell := cells[0]
		for cell in cells:
			min_cell.x = mini(min_cell.x, cell.x)
			min_cell.y = mini(min_cell.y, cell.y)
			max_cell.x = maxi(max_cell.x, cell.x)
			max_cell.y = maxi(max_cell.y, cell.y)

		r.eq(min_cell, Vector2i(-hx, -hz), "нижний угол габарита у контура %s" % shape)
		r.eq(max_cell, Vector2i(hx, hz), "верхний угол габарита у контура %s" % shape)

		for edge in [Vector2i(0, -hz), Vector2i(0, hz), Vector2i(-hx, 0), Vector2i(hx, 0)]:
			r.check(cells.has(edge),
				"у контура %s нет центральной клетки стороны %s" % [shape, edge])

	# geometry() обязана отдавать фиксированный габарит и валидный контур
	for i in range(500):
		var cfg := RoomGenerator.geometry(rng)
		r.eq(int(cfg["grid_w"]), RoomGenerator.GRID_W, "geometry отдаёт фиксированную ширину")
		r.eq(int(cfg["grid_d"]), RoomGenerator.GRID_D, "geometry отдаёт фиксированную глубину")
		r.check(RoomGenerator.SHAPES.has(str(cfg["shape"])), "контур из списка")
		r.check(RoomGenerator.THEMES.has(str(cfg["theme"])), "тема из списка")
		r.check(cfg.has("floor_color"), "есть цвет пола")

	r.finish(self)
```

- [ ] **Step 2: Запустить и убедиться, что падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_room_geometry.gd; echo "код возврата = $?"
```
Expected: ошибка об отсутствии `RoomGenerator.GRID_W` или `RoomGenerator.geometry`, код возврата не 0.

- [ ] **Step 3: Переписать RoomGenerator**

Заменить в `scripts/RoomGenerator.gd` всё от строки `const THEMES` до конца функции `describe` (включительно) на следующее; `cells_for` ниже остаётся без изменений:

```gdscript
const THEMES := ["песчаная", "каменная", "багровая", "сумеречная"]
const CELL_SIZE := 2.0

## Габарит комнаты фиксирован: комнаты складываются в сетку этажа, центр
## комнаты считается как cell * (ROOM_WIDTH, ROOM_DEPTH). Числа обязаны быть
## нечётными в клетках, иначе у стороны нет центральной клетки и дверь некуда
## поставить.
const GRID_W := 13
const GRID_D := 11
const ROOM_WIDTH := float(GRID_W) * CELL_SIZE   ## 26.0 м
const ROOM_DEPTH := float(GRID_D) * CELL_SIZE   ## 22.0 м

const SHAPES := [
	"квадратная", "прямоугольная", "восьмиугольная", "ромбовидная",
	"Г-образная", "крестовая", "с вырезом"
]

## Цвет пола под тему - единственное, что тема меняет механически безопасно.
const THEME_FLOOR := {
	"песчаная": Color(0.74, 0.62, 0.43),
	"каменная": Color(0.52, 0.51, 0.48),
	"багровая": Color(0.56, 0.33, 0.30),
	"сумеречная": Color(0.36, 0.38, 0.47),
}


## Только геометрия и оформление. Баланс - количество врагов, их состав,
## лимиты - живёт в ThreatCurve: раньше планировщик и балансировщик сидели в
## одном файле, и это мешало тестировать обоих.
static func geometry(rng: RandomNumberGenerator) -> Dictionary:
	var shape: String = SHAPES[rng.randi_range(0, SHAPES.size() - 1)]
	var theme: String = THEMES[rng.randi_range(0, THEMES.size() - 1)]
	return {
		"shape": shape,
		"theme": theme,
		"grid_w": GRID_W,
		"grid_d": GRID_D,
		"width": ROOM_WIDTH,
		"depth": ROOM_DEPTH,
		"floor_color": THEME_FLOOR.get(theme, Color(0.74, 0.62, 0.43)),
	}


## Короткое описание для экрана перехода.
static func describe(cfg: Dictionary) -> String:
	return "Этаж %d · комната %s · %s" % [
		int(cfg.get("floor_number", 1)),
		str(cfg.get("shape", "прямоугольная")),
		str(cfg.get("theme", "каменная"))]
```

- [ ] **Step 4: Запустить и убедиться, что проходит**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_room_geometry.gd; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/RoomGenerator.gd tools/check_room_geometry.gd tools/check_room_geometry.gd.uid
git commit -m "$(cat <<'EOF'
RoomGenerator сужается до геометрии, габарит комнаты фиксирован

Баланс уехал в ThreatCurve. Габарит 13x11 клеток (26x22 м) нужен, чтобы
комнаты складывались в сетку этажа; нечётность в клетках гарантирует
центральную клетку у каждой стороны, через которую и проходит дверь.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: DungeonRoom — четыре двери с состояниями

Сейчас комната знает одну дверь-вход (всегда открыта) и одну дверь-выход (с блокиратором). В сетке дверей до четырёх, и у каждой своё состояние.

**Files:**
- Modify: `scripts/DungeonRoom.gd`

- [ ] **Step 1: Заменить поля входа/выхода на словари дверей**

В `scripts/DungeonRoom.gd` заменить блок объявлений (строки с `var config` по `var _door_panel`) на:

```gdscript
var config: Dictionary = {}
var visuals_enabled: bool = true

## side -> FloorPlan.DoorState. Состояние двери живёт в FloorPlan: он не
## зависит ни от одного узла, поэтому зависимость односторонняя.
var doors: Dictionary = {}

var _cells: Dictionary = {}
var _min_cell := Vector2i.ZERO
var _max_cell := Vector2i.ZERO
var _blockers: Dictionary = {}   ## side -> CollisionShape3D
var _panels: Dictionary = {}     ## side -> MeshInstance3D
```

Удалить константу `DOOR_NONE` и поля `entrance_side`, `exit_side`.

- [ ] **Step 2: Переписать setup и постройку стен**

Заменить `setup` и блок постройки дверей в `_build` на:

```gdscript
func setup(new_config: Dictionary, center: Vector3, new_doors: Dictionary,
		show_visuals: bool) -> void:
	config = new_config
	position = center
	doors = new_doors.duplicate()
	visuals_enabled = show_visuals
	_build()
```

В `_build` заменить цикл постройки стен и последующие строки до `_create_exit_blocker(wall_body)` включительно на:

```gdscript
	for cell in cells:
		for side in range(4):
			var neighbour := cell + _side_cell_offset(side)
			if _cells.has(neighbour):
				continue
			# Проём оставляем только в центральной клетке той стороны,
			# где есть дверь. Остальное - стена.
			if doors.has(side) and _is_center_door_cell(cell, side):
				continue
			_add_wall(wall_body, wall_visual, cell, side, wall_material)

	for side in doors.keys():
		var state: int = int(doors[side])
		_add_door_frame(wall_visual, side, wall_material,
			state == FloorPlan.DoorState.OPEN)
		_create_door_blocker(wall_body, side)
		set_door_state(side, state)
```

- [ ] **Step 3: Заменить _create_exit_blocker и set_exit_open**

Удалить `_create_exit_blocker`, `set_exit_open`, `get_exit_position`, `get_exit_side`, `get_connection_center` и вставить:

```gdscript
func _create_door_blocker(body: StaticBody3D, side: int) -> void:
	var data := _door_transform(side)
	var blocker := CollisionShape3D.new()
	blocker.name = "DoorBlocker_%d" % side
	var shape := BoxShape3D.new()
	shape.size = data[1]
	blocker.shape = shape
	blocker.position = data[0]
	body.add_child(blocker)
	_blockers[side] = blocker

	if visuals_enabled:
		var panel := MeshInstance3D.new()
		panel.name = "ClosedDoor_%d" % side
		panel.position = data[0]
		add_child(panel)
		var decor := load("res://scripts/FortressDecor.gd")
		decor.gate(panel, side)
		_panels[side] = panel


func set_door_state(side: int, state: int) -> void:
	if not doors.has(side):
		return
	doors[side] = state
	var open := state == FloorPlan.DoorState.OPEN
	var blocker: CollisionShape3D = _blockers.get(side)
	if blocker != null:
		# set_deferred обязателен: форму нельзя включать и выключать изнутри
		# физического шага, в котором её может опрашивать сервер.
		blocker.set_deferred("disabled", open)
	var panel: MeshInstance3D = _panels.get(side)
	if panel != null:
		panel.visible = not open


func door_state(side: int) -> int:
	return int(doors.get(side, FloorPlan.DoorState.LOCKED_BY_FIGHT))


func open_sides() -> Array[int]:
	var out: Array[int] = []
	for side in doors.keys():
		if int(doors[side]) == FloorPlan.DoorState.OPEN:
			out.append(side)
	return out


## Точка в мировых координатах по центру проёма. Используется и для подсказки
## «дверь открыта», и для переноса бойцов в соседнюю комнату.
func door_position(side: int) -> Vector3:
	return to_global(_side_center(side) + Vector3.UP * 0.15)


## Точка внутри комнаты, на шаг от двери: сюда ставим бойцов после перехода,
## чтобы они не оказались в самом проёме и не перешли обратно тем же кадром.
func inside_door_position(side: int) -> Vector3:
	var inward := -DungeonRoom.side_direction(side) * CELL_SIZE
	return to_global(_side_center(side) + inward + Vector3.UP * 0.15)
```

- [ ] **Step 4: Проверить, что проект парсится**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --import 2>&1 | grep -iE "error|SCRIPT ERROR" | head -20; echo "---"
```
Expected: среди строк не должно быть ошибок в `DungeonRoom.gd`. Ошибки в `Arena.gd` на этом шаге ожидаемы — `Arena` ещё зовёт удалённые `set_exit_open` и `get_exit_position`; они уйдут в Task 8.

- [ ] **Step 5: Commit**

```bash
git add scripts/DungeonRoom.gd
git commit -m "$(cat <<'EOF'
DungeonRoom: до четырёх дверей с состояниями вместо входа и выхода

В сетке этажа у комнаты бывает до четырёх соседей, и у каждой двери своё
состояние: открыта, заперта боем, заперта на ключ, треснувшая стена.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: DungeonFloor — ленивая постройка и стыковка

Комнаты строятся при первом входе, а не все сразу: этаж на 19 комнат с потолками и лампами — это десятки тысяч узлов.

**Files:**
- Create: `scripts/run/DungeonFloor.gd`
- Create: `tools/check_dungeon_floor.gd`
- Create: `tools/check_dungeon_floor.tscn`

- [ ] **Step 1: Написать падающую проверку стыковки**

`tools/check_dungeon_floor.gd`:

```gdscript
extends Node

## Стыковка дверей в МИРОВЫХ координатах. Именно здесь ловятся расхождения
## габарита и шага сетки: если они разойдутся, между комнатами появится щель
## или комнаты налезут друг на друга, а на глаз это заметно не сразу.

func _ready() -> void:
	var r := TestReport.new("DungeonFloor")
	var rng := RandomNumberGenerator.new()
	rng.seed = 99

	for attempt in range(12):
		var plan := FloorPlan.generate(rng.randi_range(1, 5), rng)
		var floor_node := DungeonFloor.new()
		add_child(floor_node)
		floor_node.setup(plan, false)

		# Шаг сетки обязан совпадать с габаритом комнаты
		var c0 := floor_node.world_center_of(Vector2i(0, 0))
		var cx := floor_node.world_center_of(Vector2i(1, 0))
		var cz := floor_node.world_center_of(Vector2i(0, 1))
		r.in_range(cx.x - c0.x, RoomGenerator.ROOM_WIDTH, RoomGenerator.ROOM_WIDTH,
			"шаг сетки по x равен ширине комнаты")
		r.in_range(cz.z - c0.z, RoomGenerator.ROOM_DEPTH, RoomGenerator.ROOM_DEPTH,
			"шаг сетки по z равен глубине комнаты")

		# Строим все комнаты и сверяем двери соседей
		for cell in plan.rooms.keys():
			floor_node.room_at(cell)
		await get_tree().process_frame

		for cell in plan.rooms.keys():
			var room: DungeonRoom = floor_node.room_at(cell)
			r.check(room != null, "комната %s построена" % cell)
			for side in plan.doors_of(cell).keys():
				var other: Vector2i = cell + FloorPlan.SIDE_OFFSETS[side]
				var other_room: DungeonRoom = floor_node.room_at(other)
				var back_side := FloorPlan.opposite_side(side)
				var here := room.door_position(side)
				var there := other_room.door_position(back_side)
				r.in_range(here.distance_to(there), 0.0, 0.05,
					"проёмы %s сторона %d и %s сторона %d совпадают"
						% [cell, side, other, back_side])

		# side_between обязана согласовываться со смещениями сетки
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(3, 2)), 0, "север")
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(3, 4)), 1, "юг")
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(4, 3)), 2, "восток")
		r.eq(FloorPlan.side_between(Vector2i(3, 3), Vector2i(2, 3)), 3, "запад")

		floor_node.queue_free()
		await get_tree().process_frame

	r.finish(get_tree())
```

`tools/check_dungeon_floor.tscn`:

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tools/check_dungeon_floor.gd" id="1_d"]

[node name="CheckDungeonFloor" type="Node"]
script = ExtResource("1_d")
```

- [ ] **Step 2: Запустить и убедиться, что падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight res://tools/check_dungeon_floor.tscn; echo "код возврата = $?"
```
Expected: ошибка об отсутствии `DungeonFloor`, код возврата не 0.

- [ ] **Step 3: Написать DungeonFloor**

`scripts/run/DungeonFloor.gd`:

```gdscript
class_name DungeonFloor
extends Node3D

## Физические комнаты этажа.
##
## Комнаты строятся при первом входе, а не все сразу: этаж на девятнадцать
## комнат с перекрытиями и лампами - это десятки тысяч узлов, и строить их
## заранее незачем, половину игрок не посетит.

signal room_built(cell: Vector2i, room: DungeonRoom)

var plan: FloorPlan = null
var current_cell: Vector2i = Vector2i(-1, -1)
var visuals_enabled: bool = true

var _rooms: Dictionary = {}   ## Vector2i -> DungeonRoom
var _rng := RandomNumberGenerator.new()


func setup(new_plan: FloorPlan, show_visuals: bool) -> void:
	plan = new_plan
	visuals_enabled = show_visuals
	_rng.randomize()
	_rooms.clear()
	current_cell = Vector2i(-1, -1)


## Центр комнаты в локальных координатах этажа. Шаг сетки равен габариту
## комнаты: соседние комнаты стоят стена к стене, коридоров нет.
func world_center_of(cell: Vector2i) -> Vector3:
	return Vector3(
		float(cell.x) * RoomGenerator.ROOM_WIDTH,
		0.0,
		float(cell.y) * RoomGenerator.ROOM_DEPTH)


func room_at(cell: Vector2i) -> DungeonRoom:
	if _rooms.has(cell):
		return _rooms[cell]
	if plan == null or not plan.has_room(cell):
		return null

	var spec := plan.spec(cell)
	var cfg := RoomGenerator.geometry(_rng)
	cfg["floor_number"] = plan.floor_number
	cfg["type"] = spec["type"]
	cfg["cell"] = cell

	var room := DungeonRoom.new()
	room.name = "Room_%d_%d" % [cell.x, cell.y]
	add_child(room)
	room.setup(cfg, world_center_of(cell), plan.doors_of(cell), visuals_enabled)
	_rooms[cell] = room
	room_built.emit(cell, room)
	return room


func built_room(cell: Vector2i) -> DungeonRoom:
	return _rooms.get(cell)


## Помечает клетку текущей и строит её, если ещё не построена. Соседей тоже
## строим заранее: иначе при переходе игрок на кадр проваливается в пустоту,
## пока строится следующая комната.
func enter_cell(cell: Vector2i) -> DungeonRoom:
	var room := room_at(cell)
	if room == null:
		return null
	current_cell = cell
	for side in plan.doors_of(cell).keys():
		room_at(cell + FloorPlan.SIDE_OFFSETS[side])
	return room


func current_room() -> DungeonRoom:
	return built_room(current_cell)
```

- [ ] **Step 4: Запустить и убедиться, что проходит**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight res://tools/check_dungeon_floor.tscn; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/DungeonFloor.gd scripts/run/DungeonFloor.gd.uid tools/check_dungeon_floor.gd tools/check_dungeon_floor.gd.uid tools/check_dungeon_floor.tscn
git commit -m "$(cat <<'EOF'
DungeonFloor: ленивая постройка комнат и стыковка по сетке

Шаг сетки равен габариту комнаты, соседи строятся заранее - иначе при
переходе игрок на кадр проваливается в пустоту. Проверка сверяет проёмы
соседних комнат в мировых координатах: расхождение габарита и шага сетки
на глаз заметно не сразу.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Arena — бой приходит снаружи

`Arena` перестаёт сама выдумывать волны в игре. Путь обучения (`waves_in_room == 0`) не меняется: флаг `encounter_driven` по умолчанию `false`.

**Files:**
- Modify: `scripts/Arena.gd`

- [ ] **Step 1: Добавить флаг, сигнал и удалить игровую логику комнат**

В `scripts/Arena.gd` в группе «Комната» заменить экспорт на:

```gdscript
@export_group("Комната")
## Сколько волн отбить, прежде чем откроется выход. 0 - бесконечная арена
## (так работает обучение).
@export var waves_in_room: int = 0
## true - волны не генерируются вовсе, набор врагов приходит снаружи через
## spawn_encounter. Так работает игра: комната это один бой, а не серия волн.
## В обучении флаг остаётся false, и старый бесконечный режим не меняется.
@export var encounter_driven: bool = false
```

Добавить к сигналам наверху файла:

```gdscript
signal encounter_cleared()
```

Удалить из файла: `signal room_cleared`, `exit_radius`, `exit_open`, `exit_position`, `_exit_marker`, `room_index`, `_dungeon_mode`, `_dungeon_root`, `_dungeon_rooms`, `_current_dungeon_room`, и функции `_enable_dungeon_mode`, `_room_half_extents`, `_pick_exit_side`, `_build_first_dungeon_room`, `advance_to_room`, `apply_room`, `_open_exit`, `_close_exit`, `_show_exit_marker`, `fighter_at_exit`, `_set_floor_color`.

Сигнал `wave_cleared` остаётся: его эмитит бесконечный режим, на котором стоит обучение.

Вместо удалённой ссылки на комнату завести точку спавна, которую задаёт снаружи:

```gdscript
## Комната, в которой идёт текущий бой. Ставится снаружи (DungeonFloor).
## Нужна только для выбора точек спавна: Arena про этажи ничего не знает.
var combat_room: DungeonRoom = null
```

- [ ] **Step 2: Заменить волновой цикл и спавн на учёт encounter_driven**

Заменить `_physics_process` на:

```gdscript
func _physics_process(delta: float) -> void:
	if not _started or not any_fighter_alive():
		return

	_update_potions(delta)
	_update_zombie_targets(delta)
	if revive_enabled:
		_update_revive(delta)

	if _alive_count > 0:
		return

	if encounter_driven:
		# Набор кончился - сообщаем наружу один раз и ждём следующего.
		if _wave_live:
			_wave_live = false
			encounter_cleared.emit()
		return

	if _wave_live:
		_wave_live = false
		wave_cleared.emit(wave_index)
	_wave_timer -= delta
	if _wave_timer <= 0.0:
		_start_next_wave()
```

В `_pick_spawn_transform` и `_spawn_potion` заменить обращения `_dungeon_mode and _current_dungeon_room != null` на `combat_room != null`, а `_current_dungeon_room` на `combat_room`. В `_pick_spawn_transform` также заменить вычисление `floor_y`:

```gdscript
	var floor_y := global_position.y
	if combat_room != null:
		floor_y = combat_room.global_position.y
```

В конце `reset_arena` заменить `_start_next_wave()` на:

```gdscript
	# В режиме encounter_driven набор врагов присылают снаружи: арена не
	# должна стартовать бой сама, иначе комната получит лишнюю волну.
	if not encounter_driven:
		_start_next_wave()
```

- [ ] **Step 3: Добавить clear_room**

Вставить в секцию «Сброс эпизода», рядом с `reset_arena`:

```gdscript
## Готовит арену к бою в другой комнате: гасит врагов и зелья, но бойцов НЕ
## трогает.
##
## Полный reset_arena здесь не годится: он зовёт Gladiator.reset_state, а тот
## ставит health = max_health и снимает _downed. То есть поверженный напарник
## бесплатно поднимался бы на каждом переходе в дверь, а здоровье команды
## восстанавливалось бы полностью. Заодно отпадает нужда переносить здоровье
## долей: max_health при переходе не меняется, и абсолютное значение просто
## сохраняется само.
func clear_room() -> void:
	for z in _pool:
		if z.is_alive() or z.retiring:
			z.deactivate()
	for p in _potions:
		p.deactivate()
	revive_progress = 0.0
	revive_target = null
	_wave_live = false
	_alive_count = 0
	wave_index = 0
	_started = true
```

- [ ] **Step 4: Добавить spawn_encounter**

Вставить в секцию «Волны»:

```gdscript
## Ставит готовый набор врагов. Каждый элемент specs - словарь:
##   variant: int (Zombie.Variant)
##   health_scale, speed_scale, damage_scale, cooldown_scale: float
##
## Позиции арена выбирает сама через _pick_spawn_transform: она знает про
## комнату и про минимальную дистанцию до бойцов, а вызывающий - нет.
func spawn_encounter(specs: Array) -> void:
	if not encounter_driven:
		push_warning("Arena.spawn_encounter вызван без encounter_driven")
	for spec in specs:
		var z := _get_free_zombie()
		if z == null:
			break
		var spawn := _pick_spawn_transform()
		var target := closest_fighter_to(spawn.origin)
		z.set_variant(int(spec.get("variant", Zombie.Variant.NORMAL)))
		z.set_threat_scaling(
			float(spec.get("health_scale", 1.0)),
			float(spec.get("speed_scale", 1.0)),
			float(spec.get("damage_scale", 1.0)),
			float(spec.get("cooldown_scale", 1.0)))
		z.activate(spawn, target if target != null else gladiator)
		_alive_count += 1

	_wave_live = _alive_count > 0
	wave_index += 1
	wave_started.emit(wave_index, specs.size())
```

- [ ] **Step 5: Проверить, что проект парсится и обучение не тронуто**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --import 2>&1 | grep -iE "SCRIPT ERROR|Parse Error" | head -20; echo "--- конец ошибок ---"
```
Expected: ошибок в `Arena.gd`, `DungeonRoom.gd`, `RoomGenerator.gd` нет. Ошибки в `GameScreen.gd` ожидаемы — он ещё зовёт `apply_room`, `advance_to_room` и `fighter_at_exit`; это Task 13.

Run (путь обучения обязан остаться рабочим):
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight res://tools/check_variants.tscn; echo "код возврата = $?"
```
Expected: печатает размер наблюдений и состав волн, как раньше, код возврата `0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/Arena.gd
git commit -m "$(cat <<'EOF'
Arena: бой приходит снаружи через spawn_encounter

Комната теперь один бой, а не серия волн, и набор врагов присылает
DungeonFloor. Путь обучения не тронут: encounter_driven по умолчанию false,
и waves_in_room == 0 работает как раньше. Логика достройки комнат цепочкой
удалена - её место занял DungeonFloor.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: RunState — состояние забега

**Files:**
- Create: `scripts/run/RunState.gd`
- Create: `tools/check_run_state.gd`

- [ ] **Step 1: Написать падающую проверку**

`tools/check_run_state.gd`:

```gdscript
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
```

- [ ] **Step 2: Запустить и убедиться, что падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_run_state.gd; echo "код возврата = $?"
```
Expected: `Identifier "RunState" not declared`, код возврата не 0.

- [ ] **Step 3: Написать RunState**

`scripts/run/RunState.gd`:

```gdscript
class_name RunState
extends RefCounted

## Состояние забега: кошелёк, взятые апгрейды, карта посещённого.
##
## Отдельно от Arena намеренно: Arena это окружение обучения, и рогалик-
## экономика в ней стала бы миной под обучением.

signal changed()

var floor_number: int = 1
var coins: int = 0
var keys: int = 1
var bombs: int = 1
var taken_upgrades: Array[String] = []

var visited: Dictionary = {}   ## Vector2i -> true
var cleared: Dictionary = {}   ## Vector2i -> true


func add_coins(amount: int) -> void:
	coins = maxi(0, coins + amount)
	changed.emit()


func spend_coins(amount: int) -> bool:
	if amount > coins:
		return false
	coins -= amount
	changed.emit()
	return true


func add_keys(amount: int) -> void:
	keys = maxi(0, keys + amount)
	changed.emit()


func use_key() -> bool:
	if keys <= 0:
		return false
	keys -= 1
	changed.emit()
	return true


func add_bombs(amount: int) -> void:
	bombs = maxi(0, bombs + amount)
	changed.emit()


func use_bomb() -> bool:
	if bombs <= 0:
		return false
	bombs -= 1
	changed.emit()
	return true


func mark_visited(cell: Vector2i) -> void:
	visited[cell] = true
	changed.emit()


func is_visited(cell: Vector2i) -> bool:
	return visited.has(cell)


func mark_cleared(cell: Vector2i) -> void:
	cleared[cell] = true
	changed.emit()


func is_cleared(cell: Vector2i) -> bool:
	return cleared.has(cell)


## Сколько боевых комнат этажа зачищено. Это числитель глубины в ThreatCurve,
## поэтому считаем только бой: сокровищница и лавка в прогресс не идут.
func cleared_combat_rooms(plan: FloorPlan) -> int:
	if plan == null:
		return 0
	var n := 0
	for cell in cleared.keys():
		if not plan.has_room(cell):
			continue
		var room_type := int(plan.spec(cell)["type"])
		if room_type == FloorPlan.RoomType.COMBAT or room_type == FloorPlan.RoomType.LOCKED:
			n += 1
	return n


## Спуск на следующий этаж. Кошелёк и апгрейды переносятся, карта - нет.
func next_floor() -> void:
	floor_number += 1
	visited.clear()
	cleared.clear()
	changed.emit()
```

- [ ] **Step 4: Запустить и убедиться, что проходит**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_run_state.gd; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/RunState.gd scripts/run/RunState.gd.uid tools/check_run_state.gd tools/check_run_state.gd.uid
git commit -m "$(cat <<'EOF'
RunState: кошелёк, апгрейды и карта забега

Отдельно от Arena намеренно: Arena это окружение обучения, и рогалик-
экономика в ней стала бы миной под обучением. cleared_combat_rooms считает
только бой - это числитель глубины в ThreatCurve.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Монеты как подбираемый предмет

Повторяем готовый приём из `Potion`: пул, `activate`/`deactivate`/`is_active`, подбор сравнением дистанций без `Area3D`.

**Files:**
- Create: `scripts/run/Pickup.gd`
- Create: `scenes/Pickup.tscn`

- [ ] **Step 1: Написать Pickup**

`scripts/run/Pickup.gd`:

```gdscript
class_name Pickup
extends Node3D

## Подбираемый предмет: монета, ключ, бомба.
##
## Сделан по образцу Potion: пул, activate/deactivate, подбор сравнением
## дистанций в хозяине пула, а не через Area3D. Area3D на десятке монет в
## каждой комнате это десяток лишних тел в физическом мире на кадр.

enum Kind { COIN, KEY, BOMB }

const COLORS := {
	Kind.COIN: Color(0.96, 0.78, 0.26),
	Kind.KEY: Color(0.82, 0.86, 0.92),
	Kind.BOMB: Color(0.22, 0.22, 0.26),
}

@export var spin_speed: float = 2.2
@export var bob_height: float = 0.12

var kind: int = Kind.COIN

var _active: bool = false
var _time: float = 0.0
var _base_y: float = 0.0
var _mesh: MeshInstance3D = null
var _material: StandardMaterial3D = null


func _ready() -> void:
	_mesh = get_node_or_null("Mesh") as MeshInstance3D
	if _mesh != null and _mesh.mesh != null:
		# Меш общий для всего пула - материал копируем, иначе смена вида
		# одной монеты перекрасит все.
		_material = StandardMaterial3D.new()
		_material.emission_enabled = true
		_material.emission_energy_multiplier = 1.4
		_mesh.material_override = _material
	deactivate()


func _process(delta: float) -> void:
	if not _active:
		return
	_time += delta
	rotate_y(spin_speed * delta)
	position.y = _base_y + sin(_time * 3.0) * bob_height


func activate(new_kind: int, at: Vector3) -> void:
	kind = new_kind
	global_position = at + Vector3.UP * 0.45
	_base_y = position.y
	_time = 0.0
	_active = true
	visible = true
	set_process(true)
	if _material != null:
		var color: Color = COLORS.get(kind, COLORS[Kind.COIN])
		_material.albedo_color = color
		_material.emission = color


func deactivate() -> void:
	_active = false
	visible = false
	set_process(false)
	position = Vector3(0.0, -100.0, 0.0)


func is_active() -> bool:
	return _active
```

- [ ] **Step 2: Создать сцену**

`scenes/Pickup.tscn`:

```
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/run/Pickup.gd" id="1_p"]

[sub_resource type="SphereMesh" id="SphereMesh_1"]
radius = 0.22
height = 0.44
radial_segments = 12
rings = 6

[node name="Pickup" type="Node3D"]
script = ExtResource("1_p")

[node name="Mesh" type="MeshInstance3D" parent="."]
mesh = SubResource("SphereMesh_1")
```

- [ ] **Step 3: Проверить, что сцена грузится**

Создать временный `tools/_probe_pickup.gd`:

```gdscript
extends SceneTree

func _init() -> void:
	var r := TestReport.new("Pickup")
	var scene: PackedScene = load("res://scenes/Pickup.tscn")
	r.check(scene != null, "сцена монеты загружается")
	var p: Pickup = scene.instantiate()
	r.check(p != null, "сцена даёт Pickup")
	r.eq(p.kind, Pickup.Kind.COIN, "вид по умолчанию - монета")
	r.check(not p.is_active(), "новый предмет неактивен")
	p.free()
	r.finish(self)
```

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/_probe_pickup.gd; echo "код возврата = $?"
rm -f tools/_probe_pickup.gd tools/_probe_pickup.gd.uid
```
Expected: `упало: 0`, код возврата `0`.

- [ ] **Step 4: Commit**

```bash
git add scripts/run/Pickup.gd scripts/run/Pickup.gd.uid scenes/Pickup.tscn
git commit -m "$(cat <<'EOF'
Pickup: монета, ключ и бомба как подбираемый предмет

Сделан по образцу Potion: пул и подбор сравнением дистанций без Area3D.
Десяток Area3D на комнату - это десяток лишних тел в физическом мире
на каждый кадр.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Сундук

**Files:**
- Create: `scripts/run/Chest.gd`
- Create: `scenes/Chest.tscn`

- [ ] **Step 1: Написать Chest**

`scripts/run/Chest.gd`:

```gdscript
class_name Chest
extends Node3D

## Сундук. Сам награду не выдаёт: эмитит opened, а что положить внутрь,
## решает тот, кто показывает оверлей выбора.

enum Kind { COMMON, LOCKED, BOSS }

signal opened(kind: int)

const COLORS := {
	Kind.COMMON: Color(0.72, 0.55, 0.26),
	Kind.LOCKED: Color(0.82, 0.66, 0.30),
	Kind.BOSS: Color(0.78, 0.30, 0.34),
}

## На таком расстоянии сундук предлагает себя открыть.
const REACH := 2.0

var kind: int = Kind.COMMON

var _open: bool = false
var _lid: MeshInstance3D = null


func _ready() -> void:
	_lid = get_node_or_null("Lid") as MeshInstance3D
	_apply_look()


func setup(new_kind: int) -> void:
	kind = new_kind
	_open = false
	_apply_look()


func _apply_look() -> void:
	if _lid == null:
		return
	var material := StandardMaterial3D.new()
	var color: Color = COLORS.get(kind, COLORS[Kind.COMMON])
	material.albedo_color = color
	material.emission_enabled = not _open
	material.emission = color
	material.emission_energy_multiplier = 0.8
	_lid.material_override = material
	# Открытая крышка откинута: видно, что сундук уже выпотрошен.
	_lid.rotation_degrees.x = -80.0 if _open else 0.0


func is_open() -> bool:
	return _open


func requires_key() -> bool:
	return kind == Kind.LOCKED


## Может ли боец открыть сундук прямо сейчас.
func can_open(state: RunState, from: Vector3) -> bool:
	if _open:
		return false
	if global_position.distance_to(from) > REACH:
		return false
	if requires_key() and state.keys <= 0:
		return false
	return true


## Открывает сундук, списав ключ, если он нужен. Возвращает false, если
## открыть нельзя - вызывающий на этом показывает подсказку.
func open(state: RunState, from: Vector3) -> bool:
	if not can_open(state, from):
		return false
	if requires_key() and not state.use_key():
		return false
	_open = true
	_apply_look()
	opened.emit(kind)
	return true
```

- [ ] **Step 2: Создать сцену**

`scenes/Chest.tscn`:

```
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://scripts/run/Chest.gd" id="1_c"]

[sub_resource type="BoxMesh" id="BoxMesh_body"]
size = Vector3(0.9, 0.5, 0.6)

[sub_resource type="BoxMesh" id="BoxMesh_lid"]
size = Vector3(0.94, 0.16, 0.64)

[node name="Chest" type="Node3D"]
script = ExtResource("1_c")

[node name="Body" type="MeshInstance3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.25, 0)
mesh = SubResource("BoxMesh_body")

[node name="Lid" type="MeshInstance3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.56, -0.3)
mesh = SubResource("BoxMesh_lid")
```

- [ ] **Step 3: Написать проверку логики сундука**

`tools/check_chest.gd`:

```gdscript
extends SceneTree

func _init() -> void:
	var r := TestReport.new("Chest")
	var scene: PackedScene = load("res://scenes/Chest.tscn")
	r.check(scene != null, "сцена сундука загружается")

	var state := RunState.new()

	var common: Chest = scene.instantiate()
	common.setup(Chest.Kind.COMMON)
	r.check(not common.requires_key(), "обычный сундук без ключа")
	r.check(common.can_open(state, Vector3.ZERO), "обычный открывается вплотную")
	r.check(not common.can_open(state, Vector3(10.0, 0.0, 0.0)),
		"издалека не открывается")
	r.check(common.open(state, Vector3.ZERO), "открылся")
	r.check(common.is_open(), "помечен открытым")
	r.check(not common.open(state, Vector3.ZERO), "второй раз не открывается")
	common.free()

	var locked: Chest = scene.instantiate()
	locked.setup(Chest.Kind.LOCKED)
	r.check(locked.requires_key(), "запертый требует ключ")
	r.eq(state.keys, 1, "ключ пока на месте")
	r.check(locked.open(state, Vector3.ZERO), "с ключом открылся")
	r.eq(state.keys, 0, "ключ списался")
	locked.free()

	var locked2: Chest = scene.instantiate()
	locked2.setup(Chest.Kind.LOCKED)
	r.check(not locked2.can_open(state, Vector3.ZERO), "без ключа не открывается")
	r.check(not locked2.open(state, Vector3.ZERO), "без ключа open возвращает false")
	locked2.free()

	r.finish(self)
```

- [ ] **Step 4: Запустить проверку**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_chest.gd; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/run/Chest.gd scripts/run/Chest.gd.uid scenes/Chest.tscn tools/check_chest.gd tools/check_chest.gd.uid
git commit -m "$(cat <<'EOF'
Chest: сундук трёх видов, запертый списывает ключ

Сам награду не выдаёт: эмитит opened, а что положить внутрь, решает тот,
кто показывает оверлей выбора.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Редкий пул апгрейдов

Только уже существующие поля `Gladiator`. Новых наблюдений и новых действий не вводим — иначе ломается политика напарника.

**Files:**
- Modify: `scripts/Upgrades.gd`
- Create: `tools/check_upgrades.gd`

- [ ] **Step 1: Написать падающую проверку**

`tools/check_upgrades.gd`:

```gdscript
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
```

- [ ] **Step 2: Запустить и убедиться, что падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_upgrades.gd; echo "код возврата = $?"
```
Expected: ошибка об отсутствии `Upgrades.RARE` или `roll_rare`, код возврата не 0.

- [ ] **Step 3: Дописать Upgrades**

В `scripts/Upgrades.gd` после `const LIST := [...]` добавить:

```gdscript
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
```

Заменить `roll` и добавить `roll_rare` и `find`:

```gdscript
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
```

В `apply` добавить в `match id` внутри цикла по бойцам, после ветки `"reach"`:

```gdscript
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
```

- [ ] **Step 4: Запустить и убедиться, что проходит**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_upgrades.gd; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/Upgrades.gd tools/check_upgrades.gd tools/check_upgrades.gd.uid
git commit -m "$(cat <<'EOF'
Upgrades: редкий пул для запертых сундуков и сундука босса

Строго из уже существующих полей Gladiator. Новое поле означало бы новое
наблюдение или новое действие, а политика напарника обучена на фиксированном
векторе. Поэтому никакого "двойного удара" - это поведение, а не параметр.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: GameScreen — склейка этажа, комнат и боя

Самая большая задача плана: `GameScreen` перестаёт водить игрока по цепочке комнат и начинает водить по сетке.

**Files:**
- Modify: `scripts/ui/GameScreen.gd`

- [ ] **Step 1: Заменить поля комнаты на состояние забега**

В `scripts/ui/GameScreen.gd` заменить объявления `_rng`, `_taken`, `_room_index`, `_room_cfg`, `_exit_hint` на:

```gdscript
var _rng := RandomNumberGenerator.new()
var _run: RunState = null
var _plan: FloorPlan = null
var _floor: DungeonFloor = null
var _door_hint: Label
var _chest_hint: Label
var _chests: Array[Chest] = []
var _pickups: Array[Pickup] = []
var _pickup_scene: PackedScene = preload("res://scenes/Pickup.tscn")
var _chest_scene: PackedScene = preload("res://scenes/Chest.tscn")

## На этом расстоянии от проёма игрок считается вошедшим в соседнюю комнату.
const DOOR_REACH := 1.6
## Сколько монет падает из сундука босса.
const BOSS_CHEST_COINS := 12
```

- [ ] **Step 2: Заменить вход в комнату и переход**

Заменить функции `_enter_room`, `_on_room_cleared`, `_update_room` целиком на:

```gdscript
# ------------------------------------------------------------------
# Этаж и комнаты
# ------------------------------------------------------------------

func _start_floor(floor_number: int) -> void:
	_plan = FloorPlan.generate(floor_number, _rng)

	if _floor != null:
		_floor.queue_free()
	_floor = DungeonFloor.new()
	_floor.name = "DungeonFloor"
	add_child(_floor)
	_floor.setup(_plan, true)

	_enter_cell(FloorPlan.START_CELL, -1)
	_show_toast("Этаж %d · комнат: %d" % [floor_number, _plan.room_count()])


## Вход в клетку. from_side - сторона, с которой пришли, чтобы поставить
## бойцов у нужной двери; -1 означает старт этажа.
func _enter_cell(cell: Vector2i, from_side: int) -> void:
	var room := _floor.enter_cell(cell)
	if room == null:
		return

	_run.mark_visited(cell)
	arena.combat_room = room

	# clear_room, а не reset_arena: второй зовёт reset_state, а тот лечит
	# команду до полного и поднимает поверженного напарника. Здоровье тут
	# просто сохраняется само - max_health при переходе не меняется.
	arena.clear_room()

	var landing := room.global_position + Vector3.UP * 0.15
	if from_side >= 0:
		landing = room.inside_door_position(from_side)
	_place_fighters(landing)

	_clear_room_contents()
	_populate_room(cell, room)
	_update_door_states(cell, room)

	_hint_time = HINT_SECONDS
	_hint_box.modulate.a = 1.0
	_hint_box.visible = true


## Бойцы ставятся у точки входа, но не друг в друга: два тела в одной позиции
## физический сервер разводит рывком в стену.
##
## reset_state здесь звать НЕЛЬЗЯ по той же причине, что и reset_arena: он
## лечит до полного и снимает _downed. Переносим только позицию и скорость.
func _place_fighters(at: Vector3) -> void:
	var fighters := arena.get_fighters()
	for i in fighters.size():
		var f: Gladiator = fighters[i]
		f.velocity = Vector3.ZERO
		f.global_position = at + Vector3(float(i) * 1.4, 0.0, 0.0)


func _populate_room(cell: Vector2i, room: DungeonRoom) -> void:
	var room_type := int(_plan.spec(cell)["type"])

	match room_type:
		FloorPlan.RoomType.START:
			return
		FloorPlan.RoomType.TREASURE:
			_add_chest(room.global_position, Chest.Kind.COMMON)
			return
		FloorPlan.RoomType.SECRET:
			_add_chest(room.global_position, Chest.Kind.LOCKED)
			return
		FloorPlan.RoomType.SHOP:
			# Лавка во втором плане; пока комната с бесплатным сундуком,
			# чтобы этаж не содержал пустого помещения.
			_add_chest(room.global_position, Chest.Kind.COMMON)
			return

	if _run.is_cleared(cell):
		return   # уже зачищено, врагов второй раз не ставим

	var count := ThreatCurve.enemy_count(_run.floor_number, _rng)
	if room_type == FloorPlan.RoomType.LOCKED:
		count = ThreatCurve.locked_room_enemy_count(_run.floor_number, _rng)
	if room_type == FloorPlan.RoomType.BOSS:
		# Босс во втором плане; пока усиленный набор, чтобы этаж имел финал.
		count = ThreatCurve.enemy_count(_run.floor_number, _rng) + 3

	arena.max_alive = count
	arena.spawn_encounter(_build_encounter(count))


func _build_encounter(count: int) -> Array:
	var t := ThreatCurve.threat(_run.floor_number,
		_run.cleared_combat_rooms(_plan), _plan.combat_room_count())
	var specs: Array = []
	for i in count:
		specs.append({
			"variant": ThreatCurve.pick_variant(_run.floor_number, _rng),
			"health_scale": ThreatCurve.health_scale(t),
			"speed_scale": ThreatCurve.speed_scale(t),
			"damage_scale": ThreatCurve.damage_scale(t),
			"cooldown_scale": ThreatCurve.cooldown_scale(t),
		})
	return specs


## Двери комнаты: бой держит их закрытыми, ключ и треснувшая стена остаются
## как задал FloorPlan.
func _update_door_states(cell: Vector2i, room: DungeonRoom) -> void:
	var fight_pending := arena.get_alive_count() > 0
	for side in _plan.doors_of(cell).keys():
		var planned := int(_plan.doors_of(cell)[side])
		if planned != FloorPlan.DoorState.OPEN:
			room.set_door_state(side, planned)
			continue
		room.set_door_state(side,
			FloorPlan.DoorState.LOCKED_BY_FIGHT if fight_pending
			else FloorPlan.DoorState.OPEN)


func _on_encounter_cleared() -> void:
	if _finished or _floor == null:
		return
	var cell := _floor.current_cell
	_run.mark_cleared(cell)

	var room := _floor.current_room()
	if room != null:
		_update_door_states(cell, room)

	var room_type := int(_plan.spec(cell)["type"])
	if room_type == FloorPlan.RoomType.BOSS:
		_add_chest(room.global_position, Chest.Kind.BOSS)
		_show_toast("Босс повержен — сундук и люк вниз")
	elif room_type == FloorPlan.RoomType.LOCKED:
		_add_chest(room.global_position + Vector3(1.6, 0.0, 0.0), Chest.Kind.LOCKED)
		_add_chest(room.global_position - Vector3(1.6, 0.0, 0.0), Chest.Kind.LOCKED)
		_show_toast("Комната зачищена — два запертых сундука")
	else:
		_show_toast("Комната зачищена — двери открыты")

	# Зелье за зачищенную комнату, а не по таймеру: таймерный спавн и был
	# одной из причин, почему давления в бою не ощущалось.
	if _rng.randf() < 0.3:
		arena.spawn_potion_at(room.get_random_floor_position(_rng))


## Переход через открытую дверь и спуск на следующий этаж.
func _update_room() -> void:
	if _floor == null or _plan == null:
		return
	var room := _floor.current_room()
	if room == null:
		return

	var cell := _floor.current_cell
	var player := arena.gladiator
	if not player.is_alive():
		return

	# Спуск: зачищенная комната босса
	if int(_plan.spec(cell)["type"]) == FloorPlan.RoomType.BOSS and _run.is_cleared(cell):
		var hatch := room.global_position
		var d_hatch := player.global_position.distance_to(hatch)
		if d_hatch <= DOOR_REACH * 2.0:
			_descend()
			return
		_door_hint.visible = true
		_door_hint.text = "Люк вниз в центре зала   (%.0f м)" % d_hatch
		return

	var nearest := -1
	var nearest_d := INF
	for side in room.open_sides():
		var d := player.global_position.distance_to(room.door_position(side))
		if d < nearest_d:
			nearest_d = d
			nearest = side

	if nearest < 0:
		_door_hint.visible = false
		return

	_door_hint.visible = true
	_door_hint.text = "Дверь открыта — проход в соседнюю комнату   (%.0f м)" % nearest_d

	if nearest_d <= DOOR_REACH:
		var target_cell: Vector2i = cell + FloorPlan.SIDE_OFFSETS[nearest]
		_door_hint.visible = false
		_enter_cell(target_cell, FloorPlan.opposite_side(nearest))


func _descend() -> void:
	if _run.floor_number >= ThreatCurve.FLOOR_COUNT:
		_finish("Забег пройден", "Все пять этажей зачищены")
		return
	_run.next_floor()
	_start_floor(_run.floor_number)
```

- [ ] **Step 3: Заменить выдачу награды за волну на сундук**

Удалить `_on_wave_cleared` и заменить `_show_upgrades` и `_on_upgrade_picked` на:

```gdscript
# ------------------------------------------------------------------
# Сундуки и награды
# ------------------------------------------------------------------

func _add_chest(at: Vector3, kind: int) -> void:
	var chest: Chest = _chest_scene.instantiate()
	add_child(chest)
	chest.global_position = at
	chest.setup(kind)
	chest.opened.connect(_on_chest_opened)
	_chests.append(chest)


func _clear_room_contents() -> void:
	for c in _chests:
		if is_instance_valid(c):
			c.queue_free()
	_chests.clear()
	for p in _pickups:
		if is_instance_valid(p):
			p.queue_free()
	_pickups.clear()


## Сундук открывается той же клавишей, что и подъём напарника. Арбитраж в
## одном месте: пока кого-то поднимают, нажатие уходит в подъём.
func _try_interact() -> void:
	if arena.revive_target != null:
		return
	var from := arena.gladiator.global_position
	for c in _chests:
		if not is_instance_valid(c) or c.is_open():
			continue
		if c.open(_run, from):
			return
		if c.global_position.distance_to(from) <= Chest.REACH and c.requires_key():
			_show_toast("Нужен ключ")
			return


func _update_chest_hint() -> void:
	var from := arena.gladiator.global_position
	for c in _chests:
		if not is_instance_valid(c) or c.is_open():
			continue
		if c.global_position.distance_to(from) > Chest.REACH:
			continue
		_chest_hint.visible = true
		_chest_hint.text = "F — открыть сундук" if not c.requires_key() \
			else ("F — открыть (нужен ключ: %d)" % _run.keys)
		return
	_chest_hint.visible = false


func _on_chest_opened(kind: int) -> void:
	if kind == Chest.Kind.BOSS:
		_run.add_coins(BOSS_CHEST_COINS)
		_run.add_keys(1)
	_show_upgrades(kind)


func _show_upgrades(chest_kind: int) -> void:
	for c in _upgrade_box.get_children():
		c.queue_free()

	var rare := chest_kind != Chest.Kind.COMMON
	var title_text := "Сундук — выбери награду"
	if rare:
		title_text = "Редкий сундук — выбери награду"
	var title := UITheme.title(title_text, 28, UITheme.ACCENT, 0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_upgrade_box.add_child(title)
	_upgrade_box.add_child(_spacer(6))

	var offered: Array = Upgrades.roll_rare(_rng, 1) if chest_kind == Chest.Kind.BOSS \
		else (Upgrades.roll_rare(_rng, 3) if rare else Upgrades.roll(_rng, 3))
	for u in offered:
		_upgrade_box.add_child(_upgrade_card(u))

	_upgrade_overlay.visible = true
	get_tree().paused = true
	_capture_mouse(false)
	Engine.time_scale = 1.0
	_stop_until_ms = 0


func _on_upgrade_picked(id: String) -> void:
	Upgrades.apply(id, arena.get_fighters(), arena)
	_run.taken_upgrades.append(id)
	_upgrade_overlay.visible = false
	get_tree().paused = false
	_capture_mouse(true)
	var u := Upgrades.find(id)
	if not u.is_empty():
		_show_toast("Взято: %s" % u["name"])
```

- [ ] **Step 4: Подключить всё в _ready, ввод и подбор монет**

В `_ready` заменить `_enter_room(1)` на:

```gdscript
	_run = RunState.new()
	# Первый этаж строится ОТЛОЖЕННО. Arena._ready() ставит свой
	# reset_arena.call_deferred() в ту же очередь, и если войти в комнату
	# раньше, этот reset погасит только что расставленных врагов и вернёт
	# бойцов на стартовую позицию арены. Отложенные вызовы выполняются в
	# порядке постановки, а арена добавлена в дерево раньше - значит её reset
	# отработает первым.
	_start_floor.call_deferred(1)
```

В `_build_arena` строку `GameConfig.apply_to_arena(arena)` дополнить — **до** `add_child(arena)`, иначе `Arena._ready()` прочитает старые значения:

```gdscript
	arena = arena_scene.instantiate()
	GameConfig.apply_to_arena(arena)   # обязательно ДО add_child
	arena.encounter_driven = true
	arena.waves_in_room = 1
	# Таймерный спавн зелий в игре выключен: зелье каждые восемь секунд и было
	# одной из причин, почему в бою не чувствовалось давления. В обучении
	# таймер остаётся - ближайшее зелье входит в наблюдения и в награду.
	arena.potion_interval = 1.0e9
	add_child(arena)
	GameConfig.apply_weak_start(arena.get_fighters())
```

В подключении сигналов арены заменить `arena.wave_cleared.connect(_on_wave_cleared)` и `arena.room_cleared.connect(_on_room_cleared)` на:

```gdscript
	arena.encounter_cleared.connect(_on_encounter_cleared)
	arena.zombie_killed.connect(_on_zombie_killed_for_loot)
```

Добавить обработку ввода и подбор:

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	if _finished or get_tree().paused:
		return
	if event.is_action_pressed("g_interact"):
		_try_interact()


## Монеты с зомби. Шанс, а не гарантия: гарантированная монета с каждого
## врага превращает кошелёк в счётчик убийств.
func _on_zombie_killed_for_loot(_total: int) -> void:
	if _rng.randf() >= 0.25:
		return
	var at := arena.gladiator.global_position
	var room := _floor.current_room() if _floor != null else null
	if room != null:
		at = room.get_random_floor_position(_rng)
	_add_pickup(Pickup.Kind.COIN, at)


func _add_pickup(kind: int, at: Vector3) -> void:
	var p: Pickup = _pickup_scene.instantiate()
	add_child(p)
	p.activate(kind, at)
	_pickups.append(p)


func _update_pickups() -> void:
	var from := arena.gladiator.global_position
	for p in _pickups:
		if not is_instance_valid(p) or not p.is_active():
			continue
		if p.global_position.distance_to(from) > 1.3:
			continue
		match p.kind:
			Pickup.Kind.COIN: _run.add_coins(1)
			Pickup.Kind.KEY: _run.add_keys(1)
			Pickup.Kind.BOMB: _run.add_bombs(1)
		p.deactivate()
		return   # один предмет за кадр, как и с зельями
```

В `_update_hud` (именно там вызывается `_update_room`, а не в `_process`) добавить рядом с `_update_room()`:

```gdscript
	_update_pickups()
	_update_chest_hint()
```

Заменить блок построения `_exit_hint` (в `_build_hud`, строки со `_exit_hint = UITheme.label(...)` по `_hud.add_child(_exit_hint)`) на две подсказки:

```gdscript
	_door_hint = UITheme.label("", 16, UITheme.GOOD)
	_door_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_door_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_door_hint.position = Vector2(0, -112)
	_door_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_door_hint.visible = false
	_hud.add_child(_door_hint)

	# Подсказка о сундуке на строку выше двери: обе могут быть видны
	# одновременно, когда сундук стоит у самого проёма.
	_chest_hint = UITheme.label("", 16, UITheme.ACCENT)
	_chest_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_chest_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_chest_hint.position = Vector2(0, -140)
	_chest_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_chest_hint.visible = false
	_hud.add_child(_chest_hint)
```

Заменить в итогах `"Комнат пройдено: %d" % maxi(_room_index - 1, 0)` на:

```gdscript
		"Этаж: %d" % _run.floor_number,
		"Комнат зачищено: %d" % _run.cleared.size(),
```

и `"Улучшений собрано: %d" % _taken.size()` на:

```gdscript
		"Улучшений собрано: %d" % _run.taken_upgrades.size(),
		"Монет: %d" % _run.coins,
```

Заменить `_chips["room"].text = str(_room_index)` и строку с `wave` на:

```gdscript
	_chips["room"].text = "%d-%d" % [_run.floor_number, _run.cleared.size()]
	_chips["wave"].text = "%d" % _run.coins
```

- [ ] **Step 5: Добавить spawn_potion_at в Arena**

В `scripts/Arena.gd` в секцию «Зелья» добавить:

```gdscript
## Положить зелье в заданную точку. Нужно игре: там зелье падает за
## зачищенную комнату, а не появляется по таймеру.
func spawn_potion_at(at: Vector3) -> void:
	for p in _potions:
		if p.is_active():
			continue
		p.activate(at)
		if visuals_enabled:
			p.visible = true
			p.set_process(true)
		potion_spawned.emit(p)
		return
```

- [ ] **Step 6: Добавить действие g_interact**

В `project.godot` в секцию `[input]` добавить после `g_revive`:

```
g_interact={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,"window_id":0,"alt_pressed":false,"shift_pressed":false,"ctrl_pressed":false,"meta_pressed":false,"pressed":false,"keycode":0,"physical_keycode":70,"key_label":0,"unicode":0,"location":0,"echo":false,"script":null)
]
}
```

- [ ] **Step 7: Проверить парсинг и запуск игровой сцены**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --import 2>&1 | grep -iE "SCRIPT ERROR|Parse Error" | head -20; echo "--- конец ошибок ---"
```
Expected: список ошибок пуст.

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight res://scenes/Game.tscn --quit-after 600 2>&1 | tail -30; echo "код возврата = $?"
```
Expected: сцена поднимается, в выводе нет `SCRIPT ERROR` и нет обращений к `nil`, код возврата `0`.

- [ ] **Step 8: Commit**

```bash
git add scripts/ui/GameScreen.gd scripts/Arena.gd project.godot
git commit -m "$(cat <<'EOF'
GameScreen водит игрока по сетке этажа, награда только из сундуков

Улучшение больше не выдаётся за каждую волну: его кладут в сундук, а
сундуки стоят в сокровищнице, в запертой комнате и за боссом. Зелье падает
за зачищенную комнату вместо таймерного спавна - таймер и был одной из
причин, почему в бою не чувствовалось давления.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Убрать утечки силы и ослабить старт

Три утечки из спеки: бесплатные +15 HP за комнату (убрано в Task 13 вместе с переписанным `_enter_cell`), таймерный спавн зелий (там же) и слишком сильный старт. Здесь — старт.

**Files:**
- Modify: `scripts/ui/GameConfig.gd`

- [ ] **Step 1: Написать падающую проверку**

`tools/check_weak_start.gd`:

```gdscript
extends SceneTree

## Слабый старт применяется ТОЛЬКО в игре. Обучение обязано идти на базовых
## значениях из Gladiator.tscn, иначе обученная политика окажется в другом
## мире, чем тот, в котором училась.
##
## ПОДВОХ: в режиме --script автозагрузок НЕ СУЩЕСТВУЕТ - идентификатор
## GameConfig там не компилируется вообще. Поэтому скрипт грузим ресурсом и
## зовём статический метод у него, а не у автозагрузки.

func _init() -> void:
	var r := TestReport.new("WeakStart")
	var scene: PackedScene = load("res://scenes/Gladiator.tscn")
	var g: Gladiator = scene.instantiate()

	# База из сцены не меняется
	r.in_range(g.max_health, 100.0, 100.0, "в сцене максимум здоровья прежний")
	r.in_range(g.sword_damage, 34.0, 34.0, "в сцене урон меча прежний")

	var config_script: GDScript = load("res://scripts/ui/GameConfig.gd")
	config_script.apply_weak_start([g])
	r.in_range(g.max_health, 70.0, 70.0, "в игре здоровья меньше")
	r.in_range(g.health, 70.0, 70.0, "здоровье подтянуто к новому максимуму")
	r.in_range(g.block_stamina_max, 70.0, 70.0, "в игре запас щита меньше")
	r.in_range(g.block_stamina, 70.0, 70.0, "запас щита подтянут")
	r.in_range(g.sword_cooldown, 0.85, 0.85, "меч бьёт реже")
	r.in_range(g.kick_cooldown, 2.2, 2.2, "пинок реже")
	r.in_range(g.sword_damage, 34.0, 34.0, "урон меча НЕ тронут")

	g.free()
	r.finish(self)
```

- [ ] **Step 2: Запустить и убедиться, что падает**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_weak_start.gd; echo "код возврата = $?"
```
Expected: ошибка об отсутствии `GameConfig.apply_weak_start`, код возврата не 0.

- [ ] **Step 3: Добавить apply_weak_start**

В `scripts/ui/GameConfig.gd` добавить константы и функцию:

```gdscript
## Слабый старт забега. Нужен, чтобы редкий сундук ощущался наградой: при
## нынешних ста единицах здоровья и кулдауне 0.7 игрок и без апгрейдов
## проходит первые комнаты не напрягаясь.
##
## Урон меча не трогаем намеренно: «два удара на зомби» - дизайн-решение с
## комментарием в Zombie.gd, иначе пинок и блок становятся ненужными. Зомби
## станет трёхударным сам, за счёт роста здоровья в ThreatCurve.
const START_MAX_HEALTH := 70.0
const START_BLOCK_STAMINA := 70.0
const START_SWORD_COOLDOWN := 0.85
const START_KICK_COOLDOWN := 2.2


## Статический намеренно: проверка запускается через --script, где автозагрузок
## не существует, и зовёт метод у загруженного ресурса скрипта. Из игры
## по-прежнему доступен как GameConfig.apply_weak_start().
static func apply_weak_start(fighters: Array) -> void:
	for f in fighters:
		if f == null:
			continue
		f.max_health = START_MAX_HEALTH
		f.health = minf(f.health, START_MAX_HEALTH)
		f.block_stamina_max = START_BLOCK_STAMINA
		f.block_stamina = minf(f.block_stamina, START_BLOCK_STAMINA)
		f.sword_cooldown = START_SWORD_COOLDOWN
		f.kick_cooldown = START_KICK_COOLDOWN
```

Удалить `apply_difficulty_to_room` (комнат с волнами больше нет) и заменить ветки `match difficulty` в `apply_to_arena` на множители кривой вместо полей волн:

```gdscript
	match difficulty:
		Difficulty.EASY:
			arena.max_potions = 3
			difficulty_threat_mult = 0.75
		Difficulty.HARD:
			arena.max_potions = 2
			difficulty_threat_mult = 1.3
		_:
			arena.max_potions = 3
			difficulty_threat_mult = 1.0
```

и добавить рядом с другими полями автозагрузки:

```gdscript
## Множитель глубины под выбранную сложность. Применяется к threat, а не к
## полям арены: так одна кривая обслуживает все три режима.
var difficulty_threat_mult: float = 1.0
```

- [ ] **Step 4: Применить множитель сложности в игре**

Вызов `GameConfig.apply_weak_start(arena.get_fighters())` уже добавлен в `_build_arena` в Task 13. Здесь остаётся множитель: в `_build_encounter` заменить вычисление `t` на:

```gdscript
	var t := ThreatCurve.threat(_run.floor_number,
		_run.cleared_combat_rooms(_plan), _plan.combat_room_count()) \
		* GameConfig.difficulty_threat_mult
```

- [ ] **Step 5: Запустить проверки**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight --script res://tools/check_weak_start.gd; echo "код возврата = $?"
```
Expected: `упало: 0`, код возврата `0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/ui/GameConfig.gd scripts/ui/GameScreen.gd tools/check_weak_start.gd tools/check_weak_start.gd.uid
git commit -m "$(cat <<'EOF'
Слабый старт забега и сложность через множитель глубины

Без слабого старта редкий сундук не ощущается наградой: при ста единицах
здоровья и кулдауне 0.7 первые комнаты проходятся не напрягаясь. Урон меча
не тронут - "два удара на зомби" это дизайн-решение, зомби станет
трёхударным сам за счёт роста здоровья в ThreatCurve.

Сложность стала множителем глубины вместо правки полей волн: одна кривая
обслуживает все три режима.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: Итоговая проверка — игра и обучение

**Files:**
- Create: `tools/check_slice_1.sh`

- [ ] **Step 1: Написать скрипт прогона всех проверок**

`tools/check_slice_1.sh`:

```bash
#!/usr/bin/env bash
# Прогон всех проверок среза 1. Любая упавшая проверка валит весь скрипт.
set -u
GODOT="C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe"
PROJECT="D:/AIfight"
failed=0

run_script() {
	echo "=== $1 ==="
	"$GODOT" --headless --path "$PROJECT" --script "res://tools/$1"
	if [ $? -ne 0 ]; then
		echo "ПРОВАЛ: $1"
		failed=1
	fi
}

run_scene() {
	echo "=== $1 ==="
	"$GODOT" --headless --path "$PROJECT" "res://tools/$1"
	if [ $? -ne 0 ]; then
		echo "ПРОВАЛ: $1"
		failed=1
	fi
}

# Новые проверки среза
run_script check_threat_curve.gd
run_script check_floor_plan.gd
run_script check_room_geometry.gd
run_script check_run_state.gd
run_script check_chest.gd
run_script check_upgrades.gd
run_script check_weak_start.gd
run_scene  check_dungeon_floor.tscn

# Существующие проверки обязаны остаться зелёными
run_script check_combat_animation.gd
run_scene  check_variants.tscn
run_scene  check_ceiling_gate.tscn

echo
if [ "$failed" -eq 0 ]; then
	echo "ВСЁ ЗЕЛЁНОЕ"
else
	echo "ЕСТЬ ПРОВАЛЫ"
fi
exit "$failed"
```

- [ ] **Step 2: Прогнать всё**

Run:
```bash
bash tools/check_slice_1.sh; echo "код возврата = $?"
```
Expected: `ВСЁ ЗЕЛЁНОЕ`, код возврата `0`. Если какая-то из существующих проверок упала — это регрессия, её нужно починить до коммита, а не принять.

- [ ] **Step 3: Проверить, что обучение действительно не тронуто**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight res://scenes/Training.tscn --quit-after 400 2>&1 | grep -iE "SCRIPT ERROR|error" | head -20; echo "--- конец ошибок ---"
```
Expected: ошибок нет. Сцена обучения поднимается, арены идут в бесконечном режиме `waves_in_room == 0`.

- [ ] **Step 4: Прогнать игру на длинной дистанции**

Run:
```bash
"C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe" --headless --path D:/AIfight res://scenes/Game.tscn --quit-after 3000 2>&1 | grep -iE "SCRIPT ERROR|nil|null instance" | head -20; echo "--- конец ошибок ---"
```
Expected: ошибок нет. Три тысячи кадров — это примерно пятьдесят секунд игры, достаточно, чтобы первая комната успела зачиститься и сработал `_on_encounter_cleared`.

- [ ] **Step 5: Commit**

```bash
git add tools/check_slice_1.sh
git commit -m "$(cat <<'EOF'
Скрипт прогона всех проверок среза 1

Существующие проверки включены в прогон намеренно: главный риск этой
переделки - регрессия в обучении, а она проявляется именно в них.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Что осталось на второй план

| Из спеки | Почему не здесь |
|---|---|
| Лавка с товарами | Нужен экран покупки и цены; в этом срезе комната лавки временно отдаёт обычный сундук |
| Ключи и бомбы как выпадающие предметы | `Pickup` их уже умеет, `RunState` считает; не хватает выпадения и подрыва стены |
| Секретка через треснувшую стену | Нужно действие `g_bomb` и разрушаемая стена; в этом срезе секретка доступна как обычный тупик с запертым сундуком |
| Босс | `class_name Boss extends Zombie`, фазы, рывок, круговой удар, требование `State.WINDUP`; в этом срезе комната босса отдаёт усиленный набор обычных врагов |
| Миникарта | `FloorPlan` уже отдаёт всё нужное, осталось нарисовать |
| Вынос `GameHud` и `RunOverlays` из `GameScreen` | `GameScreen` после этого плана вырос; раскол делается во втором плане вместе с миникартой |
| `tools/balance_run.gd` | Калибровать имеет смысл после босса: без финала этажа цифры смерти смещены |

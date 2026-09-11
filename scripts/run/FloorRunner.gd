class_name FloorRunner
extends Node3D

## Навигация по этажу: сетка комнат, переход через двери, бой за комнату,
## состояния дверей и зачистка.
##
## Вынесено из GameScreen, чтобы игровая сцена занималась интерфейсом, а не
## обходом этажа. FloorRunner не строит ни одного Control: наружу - сигналы и
## методы-запросы, а подсказки, тосты и HUD рисует GameScreen.
##
## Узел, а не RefCounted: DungeonFloor - Node3D и обязан жить в дереве, и его
## естественный хозяин - тот, кто решает, какую клетку строить. Собственного
## _process у узла нет: переход через дверь проверяет tick(), который GameScreen
## зовёт из своего кадра. Так порядок остался прежним (HUD, затем переход), а
## конец забега и пауза гасят навигацию там же, где гасят HUD.
##
## Arena по-прежнему ничего не знает про этажи: FloorRunner говорит ей, какая
## комната текущая и кого в ней ставить, и слушает encounter_cleared.

## Игрок вошёл в клетку этажа. from_side - сторона новой комнаты, через
## которую вошли; -1 - старт этажа. Испускается в самом конце входа, когда
## бойцы расставлены и развёрнуты, враги поставлены и двери выставлены.
signal room_entered(cell: Vector2i, from_side: int)
## Этаж построен, бойцы в стартовой комнате.
signal floor_started(floor_number: int, room_count: int)
## В комнате начался бой, двери заперты. Испускается внутри входа, раньше
## room_entered.
signal fight_started(cell: Vector2i, boss: bool)
## Комната зачищена впервые, двери открыты. Повторная зачистка той же клетки
## сигнала не даёт.
signal room_cleared(cell: Vector2i)
# 13b: signal reward_offered(chest_kind: int) - сундук открыт, выбор награды
# рисует GameScreen (_show_upgrades); signal descended(floor_number: int) -
# спуск через люк, GameScreen показывает тост нового этажа.

## На этом расстоянии (по горизонтали) от проёма игрок считается вошедшим в
## соседнюю комнату.
const DOOR_REACH := 1.6
## Переход - только когда игрок идёт В проём, быстрее этой скорости, м/с.
const DOOR_PUSH_SPEED := 0.3
## Бойцы после перехода встают на этой глубине от линии стены, м. Заметно
## больше DOOR_REACH: иначе вставший у порога ушёл бы обратно следующим кадром.
const ENTRY_DEPTH := 3.0
## Расстояние между бойцами поперёк стороны входа, м.
const ENTRY_SPACING := 1.5
## Запас от точки бойца до края пола: половина толщины стены (0.3) плюс
## радиус капсулы (0.4) и немного сверху.
const ENTRY_CLEARANCE := 0.8

## Единый генератор забега: планировка этажа, контуры комнат, состав врагов
## и выбор наград (GameScreen._show_upgrades). Один на всё, как и прежде: при
## заданном сиде забег повторяется целиком, а раздельные генераторы разошлись
## бы с тем, что давал этот сид раньше.
var rng := RandomNumberGenerator.new()

var _arena: Arena = null
## Множитель угрозы под сложность (GameConfig.difficulty_threat_mult).
## Приходит в setup, а не читается из автозагрузки: в режиме --script
## автозагрузок нет, и тогда FloorRunner не компилировался бы, а вместе с ним -
## любой инструмент, типизированный по нему (tools/soak_300.gd).
var _threat_mult: float = 1.0
var _run: RunState = null
var _plan: FloorPlan = null
var _floor: DungeonFloor = null
## Середина между точками, где встали бойцы при последнем входе в комнату.
## От неё (и от двери входа) Arena держит зомби на дистанции.
var _entry_point: Vector3 = Vector3.ZERO
var _last_transition_frame: int = -10
## Расстояние до ближайшей открытой двери для подсказки; -1 - подсказки нет.
var _door_hint_distance: float = -1.0
## Забег окончен: зачистки больше не засчитываются (см. halt).
var _halted: bool = false
## Состояние клеток текущего этажа между визитами, Vector2i -> Dictionary.
## См. cell_state.
var _cells: Dictionary = {}


## run_seed - сид забега; 0 - случайный. От него зависят планировка этажа,
## контуры комнат, состав врагов и (через Arena.arena_seed, который выставляет
## GameScreen) клетки их спавна. threat_mult - множитель угрозы под сложность.
func setup(arena: Arena, run_seed: int, threat_mult: float = 1.0) -> void:
	_arena = arena
	_threat_mult = threat_mult
	if run_seed != 0:
		rng.seed = run_seed
	else:
		rng.randomize()
	# RunState - сразу, а не в отложенном start_floor: HUD и итоги читают его
	# с первого же кадра.
	_run = RunState.new()
	if _arena != null:
		_arena.encounter_cleared.connect(_on_encounter_cleared)


# ------------------------------------------------------------------
# Запросы
# ------------------------------------------------------------------

func run_state() -> RunState:
	return _run


## План текущего этажа; null, пока отложенный start_floor не отработал.
func plan() -> FloorPlan:
	return _plan


## Физические комнаты текущего этажа; null до start_floor.
func dungeon() -> DungeonFloor:
	return _floor


func current_cell() -> Vector2i:
	return _floor.current_cell if _floor != null else Vector2i(-1, -1)


## Текущая комната этажа; null, пока отложенный start_floor не отработал.
func current_room() -> DungeonRoom:
	return _floor.current_room() if _floor != null else null


## Середина между точками, где встали бойцы при последнем входе.
func entry_point() -> Vector3:
	return _entry_point


## Расстояние до открытой двери, о которой стоит подсказать, или -1. Живёт
## от tick() до tick(): после перехода подсказки нет до следующего кадра.
func door_hint_distance() -> float:
	return _door_hint_distance


## Ближайшая открытая дверь текущей комнаты к точке from (по горизонтали)
## или -1. Отдаётся наружу: инструменты (tools/soak_300.gd) ведут по ней
## бойца, не зная про устройство этажа.
func nearest_open_door(from: Vector3) -> int:
	var room := current_room()
	if room == null:
		return -1
	var best := -1
	var best_d := INF
	for side in room.open_sides():
		var d := _flat_distance(from, room.door_position(side))
		if d < best_d:
			best_d = d
			best = side
	return best


## Состояние клетки этажа между визитами; создаётся при первом обращении и
## живёт до конца этажа.
##
## Сюда 13b кладёт содержимое комнаты, которое обязано пережить уход и
## возвращение: открытые сундуки, неподобранные монеты, ключи и зелья. Пока
## словарь пуст: посещение и зачистку ведёт RunState - их читают HUD и итоги
## забега, и дублировать их здесь незачем.
func cell_state(cell: Vector2i) -> Dictionary:
	if not _cells.has(cell):
		_cells[cell] = {}
	return _cells[cell]


# ------------------------------------------------------------------
# Этаж и комнаты
# ------------------------------------------------------------------

func start_floor(floor_number: int) -> void:
	if _arena == null or _run == null:
		return
	_plan = FloorPlan.generate(floor_number, rng)

	if _floor != null:
		_floor.queue_free()
	_floor = DungeonFloor.new()
	_floor.name = "DungeonFloor"
	add_child(_floor)
	# Сид геометрии - из того же rng: при заданном run_seed этаж повторяется
	# целиком, вместе с контурами комнат. «| 1» - чтобы не выпал ноль, он
	# означает «случайный».
	_floor.setup(_plan, true, rng.randi() | 1)
	# Клетки нового этажа - новые: содержимое прошлых комнат туда не переходит.
	_cells.clear()

	enter_cell(FloorPlan.START_CELL, -1)
	floor_started.emit(floor_number, _plan.room_count())


## Вход в клетку. from_side - сторона НОВОЙ комнаты, через которую вошли (у
## неё и встают бойцы); -1 - старт этажа, бойцы встают в центре.
func enter_cell(cell: Vector2i, from_side: int) -> void:
	if _floor == null or _run == null:
		return
	# 13b: до смены клетки сохранить содержимое покидаемой комнаты
	# (_floor.current_cell) в cell_state и убрать его со сцены.
	var room := _floor.enter_cell(cell)
	if room == null:
		return

	_run.mark_visited(cell)
	_arena.combat_room = room

	# clear_room, а не reset_arena: второй зовёт reset_state, а тот лечит
	# команду до полного и поднимает поверженного напарника. Здоровье тут
	# просто сохраняется само - max_health при переходе не меняется.
	_arena.clear_room()

	var spots := entry_spots(room, from_side)
	_entry_point = (spots[0] + spots[1]) * 0.5
	_place_fighters(spots)
	# На старте этажа двери входа нет, и «внутрь» не определено: бойцы стоят
	# в центре так, как их поставил reset_arena, а камера уже встала им за
	# спину по сигналу respawned.
	if from_side >= 0:
		_face_into_room(from_side)
	_last_transition_frame = Engine.get_process_frames()

	# Сначала враги, потом двери: запирать ли двери, решает число живых.
	_populate_room(cell, room, from_side)
	# 13b: вернуть сохранённое в cell_state(cell) содержимое комнаты - сундуки
	# в прежнем состоянии, неподобранные пикапы и зелья.
	_update_door_states(cell, room)

	_door_hint_distance = -1.0
	room_entered.emit(cell, from_side)


## Две точки для бойцов у входа: на полу, поперёк стороны входа (касательно
## проёму) и на ENTRY_DEPTH вглубь от линии стены.
##
## Поперёк, а не с общим смещением по оси X, как было в плане: при входе с
## востока или запада смещение по X ставило второго бойца либо в сам проём,
## либо глубже первого - и первый оказывался у порога.
static func entry_spots(room: DungeonRoom, from_side: int) -> Array[Vector3]:
	var base := room.global_position
	var inward := Vector3.ZERO
	var tangent := Vector3.RIGHT
	var depths: Array[float] = [0.0]
	if from_side >= 0:
		inward = _inward(from_side)
		tangent = Vector3.RIGHT if from_side < 2 else Vector3.BACK
		base = room.door_position(from_side)
		base.y = room.global_position.y
		# Глубину наращиваем, пока обе точки не лягут на пол с запасом: у
		# ромбовидной и восьмиугольной комнаты пол у самой стены узкий.
		depths = [ENTRY_DEPTH, ENTRY_DEPTH + 1.0, ENTRY_DEPTH + 2.0, ENTRY_DEPTH + 3.0]

	var spacings: Array[float] = [ENTRY_SPACING, 1.1]
	# Пару сдвигаем и вдоль стены. У Г-образной комнаты на входе с севера и
	# запада пол есть только по одну сторону от проёма: симметричная пара
	# там не помещается ни на какой глубине, и без сдвига один боец вставал
	# бы в стену.
	var shifts: Array[float] = [0.0, 0.75, -0.75, 1.5, -1.5, 2.25, -2.25]
	for depth in depths:
		for shift in shifts:
			var center := base + inward * depth + tangent * shift
			for spacing in spacings:
				var a := center - tangent * (spacing * 0.5)
				var b := center + tangent * (spacing * 0.5)
				if room.has_floor_at(a, ENTRY_CLEARANCE) and room.has_floor_at(b, ENTRY_CLEARANCE):
					var spots: Array[Vector3] = [a, b]
					return spots

	# Не должно случаться: средние линии комнаты есть у любого контура
	# (RoomGenerator.cells_for). Но молча ставить бойцов в стену нельзя.
	push_warning("FloorRunner: у входа %d комнаты %s не нашлось места для бойцов"
		% [from_side, room.name])
	var fallback := base + inward * ENTRY_DEPTH
	var spots: Array[Vector3] = [fallback - tangent * 0.6, fallback + tangent * 0.6]
	return spots


## Бойцы ставятся в точки входа, не друг в друга: два тела в одной позиции
## физический сервер разводит рывком в стену.
##
## reset_state здесь звать НЕЛЬЗЯ по той же причине, что и reset_arena: он
## лечит до полного и снимает _downed. Переносим только позицию и скорость -
## здоровье и «повержен» переживают переход сами.
func _place_fighters(spots: Array[Vector3]) -> void:
	var fighters := _arena.get_fighters()
	for i in fighters.size():
		var f: Gladiator = fighters[i]
		f.velocity = Vector3.ZERO
		f.global_position = spots[mini(i, spots.size() - 1)] + Vector3.UP * 0.05


## Направление внутрь комнаты от двери стороны from_side.
static func _inward(from_side: int) -> Vector3:
	return -DungeonRoom.side_direction(from_side)


## Разворот бойцов лицом в комнату после входа через сторону from_side.
##
## Позиция при переходе телепортируется, а поворот - нет: Gladiator не
## прыгает в intent_facing_yaw, а догоняет его с конечной скоростью, и тело
## сохраняло прежнее направление. Войдя спиной, игрок так и стоял лицом к
## решётке, через которую пришёл.
##
## Тело и намерение - у обоих бойцов. Напарнику этого достаточно: его
## поворотом дальше управляет политика через intent_turn. У игрока
## направление держит ещё и камера - её вслед за телом разворачивает
## GameScreen по room_entered (_snap_view_into_room).
func _face_into_room(from_side: int) -> void:
	var inward := _inward(from_side)
	var yaw := atan2(-inward.x, -inward.z)
	for f in _arena.get_fighters():
		f.global_rotation.y = yaw
		f.intent_facing_yaw = yaw


func _populate_room(cell: Vector2i, room: DungeonRoom, from_side: int) -> void:
	var room_type := int(_plan.spec(cell)["type"])

	if room_type in [FloorPlan.RoomType.START, FloorPlan.RoomType.TREASURE,
			FloorPlan.RoomType.SECRET, FloorPlan.RoomType.SHOP]:
		# 13b: сокровищница, лавка и секретка получают сундук (см. план,
		# _add_chest), но только при первом визите - дальше он живёт в
		# cell_state. В 13a эти комнаты просто пустые и без боя.
		return

	if _run.is_cleared(cell):
		return   # уже зачищено, врагов второй раз не ставим

	var count := ThreatCurve.enemy_count(_run.floor_number, rng)
	if room_type == FloorPlan.RoomType.LOCKED:
		count = ThreatCurve.locked_room_enemy_count(_run.floor_number, rng)
	elif room_type == FloorPlan.RoomType.BOSS:
		# Босс во втором плане; пока усиленный набор обычных врагов, чтобы
		# этаж имел финал.
		count += 3

	_arena.max_alive = count
	# Спека: враги не ближе 6 м от двери входа. Дверь и место, где встали
	# бойцы, - обе точки: бойцы стоят в трёх метрах от проёма.
	var keep_away: Array = [_entry_point]
	if from_side >= 0:
		keep_away.append(room.door_position(from_side))
	_arena.spawn_encounter(_build_encounter(count), keep_away)

	if _arena.get_alive_count() > 0:
		fight_started.emit(cell, room_type == FloorPlan.RoomType.BOSS)


func _build_encounter(count: int) -> Array:
	# Сложность множит глубину, а не поля арены: одна кривая обслуживает все
	# три режима. Применяется здесь и только здесь.
	var t := ThreatCurve.threat(_run.floor_number,
		_run.cleared_combat_rooms(_plan), _plan.combat_room_count()) \
		* _threat_mult
	var specs: Array = []
	for i in count:
		specs.append({
			"variant": ThreatCurve.pick_variant(_run.floor_number, rng),
			"health_scale": ThreatCurve.health_scale(t),
			"speed_scale": ThreatCurve.speed_scale(t),
			"damage_scale": ThreatCurve.damage_scale(t),
			"cooldown_scale": ThreatCurve.cooldown_scale(t),
		})
	return specs


## Двери комнаты: бой держит закрытыми все доступные входы, ключ остаётся как
## задал FloorPlan.
##
## Состояние пишется с ОБЕИХ сторон общей двери. У соседней комнаты своя
## коллизия-блокиратор на той же стене, и её устаревшее состояние (например,
## LOCKED_BY_FIGHT, оставшийся с прошлого боя, или треснувшая стена из
## постройки) заперло бы проход, открытый с этой стороны.
func _update_door_states(cell: Vector2i, room: DungeonRoom) -> void:
	var fight_pending := _arena.get_alive_count() > 0
	var doors := _plan.doors_of(cell)
	for side in doors.keys():
		var state := _effective_door_state(int(doors[side]), fight_pending)
		room.set_door_state(side, state)
		var neighbour := _floor.built_room(cell + FloorPlan.SIDE_OFFSETS[side])
		if neighbour != null:
			neighbour.set_door_state(FloorPlan.opposite_side(side), state)


## Во что превращается дверь из плана в этом срезе.
##
## Треснувшая стена открыта: бомб и подрыва ещё нет, и по пометке плана
## секретка в срезе 1 доступна как обычный тупик. Во втором плане стену
## будут открывать бомбой, и эта ветка уйдёт. Запертая на ключ дверь - тоже
## второй план: остаётся закрытой. Бой запирает всё, что доступно, включая
## открытый в срезе вход в секретку.
static func _effective_door_state(planned: int, fight_pending: bool) -> int:
	if planned == FloorPlan.DoorState.LOCKED_BY_KEY:
		return planned
	return FloorPlan.DoorState.LOCKED_BY_FIGHT if fight_pending else FloorPlan.DoorState.OPEN


## Забег окончен (GameScreen получил episode_ended): зачистки больше не
## засчитываются. Отложенный encounter_cleared пустого набора может прийти
## уже после конца, и отметка в итогах была бы ложной.
func halt() -> void:
	_halted = true


func _on_encounter_cleared() -> void:
	if _halted or _floor == null or _run == null:
		return
	var cell := _floor.current_cell
	# Отметка ровно одна: повторный сигнал для уже зачищенной клетки (его быть
	# не должно, но охрана дешевле расследования) не прибавляет прогресса.
	var first := not _run.is_cleared(cell)
	if first:
		_run.mark_cleared(cell)

	var room := _floor.current_room()
	if room != null:
		_update_door_states(cell, room)

	if first:
		# 13b: сундук босса и два запертых сундука (в cell_state, чтобы не
		# появились заново при возврате), зелье за зачистку (30%, за босса
		# гарантированно), люк вниз после босса.
		room_cleared.emit(cell)


# 13b: interact() - клавиша F, приоритет: подъём напарника, затем ближайший
# неоткрытый сундук, затем люк. GameScreen зовёт его из _unhandled_input.


## Кадр навигации: подсказка двери и переход через открытую дверь. Зовёт
## GameScreen из своего _process - только пока забег идёт.
func tick() -> void:
	var room := current_room()
	if room == null or _plan == null:
		_door_hint_distance = -1.0
		return
	var player := _arena.gladiator
	if not player.is_alive():
		_door_hint_distance = -1.0
		return

	# 13b: подбор пикапов у игрока; люк в зачищенной комнате босса - подсказка
	# и спуск по F (interact), никакого автоматического спуска по близости.

	var side := nearest_open_door(player.global_position)
	if side < 0:
		_door_hint_distance = -1.0
		return

	var d := _flat_distance(player.global_position, room.door_position(side))
	_door_hint_distance = d
	if d > DOOR_REACH:
		return

	# Переход - только когда игрок идёт В проём. Стоящий у двери (например,
	# прижатый к ней, пока её держал бой) не должен улетать в соседнюю
	# комнату в тот же миг, как она откроется.
	var push := Vector3(player.velocity.x, 0.0, player.velocity.z) \
		.dot(DungeonRoom.side_direction(side))
	if push < DOOR_PUSH_SPEED:
		return
	# Второй рубеж против мгновенного возврата: бойцы и так встают глубже
	# DOOR_REACH, но переход в том же или соседнем кадре не нужен никогда.
	if Engine.get_process_frames() - _last_transition_frame <= 1:
		return

	var target: Vector2i = _floor.current_cell + FloorPlan.SIDE_OFFSETS[side]
	if not _plan.has_room(target):
		return
	_door_hint_distance = -1.0
	enter_cell(target, FloorPlan.opposite_side(side))


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

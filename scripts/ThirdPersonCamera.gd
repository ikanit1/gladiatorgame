extends SpringArm3D

## Камера от третьего лица за спиной бойца.
##
## SpringArm3D взят не для красоты: он сам подтягивает камеру, когда между ней
## и бойцом оказывается стена. Без него на краю арены камера уходила бы
## за каменную кладку и показывала темноту.
##
## Мышь управляет только обзором. PlayerInput передаёт механике направление
## движения и прицеливания отдельно, поэтому камера не борется с поворотом тела.

@export var target_path: NodePath
@export var height: float = 1.55         ## точка, вокруг которой вращаемся
@export var distance: float = 4.6
@export var pitch_min_deg: float = -55.0
## Взгляд вверх опускает камеру: штанга смотрит назад, и при наклоне вверх
## её конец уходит вниз на distance * sin(наклон). При прежних 22 градусах
## это давало 1.55 - 4.6 * sin(20°) ≈ 0.02 м, то есть камера оказывалась
## ВНУТРИ плиты пола (она занимает -0.015..0.045) и смотрела наружу под её
## край - в пустоту за комнатой. SpringArm тут не помогает: он бросает луч,
## а луч, идущий до 0.02 м, поверхность пола на нуле не пересекает.
##
## При 10 градусах камера в худшем случае на 1.55 - 4.6 * sin(10°) ≈ 0.75 м -
## с запасом над полом. Потолок в три метра смотреть выше всё равно не даёт.
@export var pitch_max_deg: float = 10.0
@export var follow_speed: float = 22.0
@export var mouse_sensitivity: float = 0.0022

@export_group("Тряска")
@export var shake_decay: float = 3.2
@export var shake_angle_deg: float = 0.8
@export var shake_angle_kick: float = 0.6

var _target: Node3D
var _pitch: float = -0.28
## Собственный угол камеры. Раньше она жёстко копировала поворот бойца, и
## «относительно камеры» означало «относительно персонажа» - при таком раскладе
## нормальное WASD невозможно в принципе.
var _yaw: float = 0.0
var _shake: float = 0.0
var _shake_seed: float = 0.0
var _cam: Camera3D
var _last_frame_usec: int = 0


func _ready() -> void:
	spring_length = distance
	# Луч не должен цепляться за самого бойца и за врагов - только за стены
	collision_mask = 1
	_cam = get_node_or_null("Camera3D") as Camera3D
	_shake_seed = randf() * 100.0
	if target_path != NodePath():
		set_target(get_node_or_null(target_path) as Node3D)


## Куда смотрит камера по горизонтали. По этому углу PlayerInput строит
## направление движения.
func get_yaw() -> float:
	return _yaw


## Толчок камеры. Значения складываются не суммой, а максимумом: серия ударов
## подряд не должна копиться в неуправляемую болтанку.
func shake(amount: float) -> void:
	_shake = maxf(_shake, clampf(amount, 0.0, 1.0))


func set_target(node: Node3D) -> void:
	if is_instance_valid(_target):
		if _target is CollisionObject3D:
			remove_excluded_object(_target.get_rid())
		if _target.has_signal("respawned") and _target.is_connected("respawned", _reset_follow):
			_target.disconnect("respawned", _reset_follow)
	_target = node
	set_process(node != null)
	if node != null:
		_reset_follow()
		if node is CollisionObject3D:
			add_excluded_object(node.get_rid())
		if node.has_signal("respawned"):
			node.connect("respawned", _reset_follow)

func _reset_follow() -> void:
	global_position = _target.global_position + Vector3.UP * height
	_yaw = _target.global_rotation.y
	_shake = 0.0
	_last_frame_usec = Time.get_ticks_usec()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured():
		_yaw = wrapf(_yaw - event.screen_relative.x * mouse_sensitivity, -PI, PI)
		_pitch = clampf(_pitch - event.screen_relative.y * mouse_sensitivity,
			deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))


func _process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	# Camera response stays consistent during combat hit-stop and after a pause.
	var now := Time.get_ticks_usec()
	var camera_delta := clampf(float(now - _last_frame_usec) / 1000000.0, 0.0, 0.05) if _last_frame_usec > 0 else delta
	_last_frame_usec = now

	var desired := _target.global_position + Vector3.UP * height
	# Экспоненциальное сглаживание позиции, но НЕ поворота: камера должна
	# отвечать на мышь мгновенно, иначе прицеливание ощущается ватным.
	var k := 1.0 - exp(-follow_speed * camera_delta)
	global_position = desired if global_position.distance_squared_to(desired) > 36.0 else global_position.lerp(desired, k)

	rotation.y = _yaw
	rotation.x = _pitch
	rotation.z = 0.0

	_apply_shake(camera_delta)


func _apply_shake(delta: float) -> void:
	if _cam == null:
		return

	if _shake <= 0.001:
		_shake = 0.0
		_cam.rotation = Vector3.ZERO
		return

	# ТОЛЬКО поворот камеры, никаких присваиваний position.
	# SpringArm3D сам расставляет дочерние узлы вдоль своей оси Z по результату
	# проверки на столкновение. Запись в _cam.position обнуляла эту координату,
	# и камера схлопывалась в точку крепления - то есть внутрь гладиатора.
	var t := float(Time.get_ticks_msec()) * 0.001 + _shake_seed
	# Квадрат затухания: пик резкий, хвост короткий - иначе картинка "плывёт"
	var k := _shake * _shake
	var ang := deg_to_rad(shake_angle_deg) * k

	_cam.rotation = Vector3(
		sin(t * 47.0) * ang,
		sin(t * 39.0 + 1.7) * ang,
		sin(t * 53.0 + 0.9) * deg_to_rad(shake_angle_kick) * k)

	_shake = move_toward(_shake, 0.0, shake_decay * delta)


static func _mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

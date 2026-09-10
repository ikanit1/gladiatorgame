extends Node

## Camera-relative manual input. AI still uses the original scalar intents.
@export var attack_buffer_time: float = 0.25

@onready var _g: Gladiator = get_parent() as Gladiator
var _queued_attack: int = -1
var _buffer_left: float = 0.0

func _ready() -> void:
	process_physics_priority = -10
	if _g == null:
		set_physics_process(false)
		return
	_g.attack_started.connect(_on_attack_started)
	_g.respawned.connect(clear_input)
	_g.downed.connect(clear_input)
	_g.died.connect(clear_input)
	_g.revived.connect(_on_revived)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED or what == NOTIFICATION_DISABLED:
		clear_input()

func _unhandled_input(event: InputEvent) -> void:
	if _g == null or not _g.is_alive() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event.is_action_pressed("g_sword"):
		queue_attack(Gladiator.AttackType.SWORD)
	elif event.is_action_pressed("g_kick"):
		queue_attack(Gladiator.AttackType.KICK)

func queue_attack(kind: int) -> void:
	# Only the latest press is buffered, so clicks cannot build an unwanted combo.
	_queued_attack = kind
	_buffer_left = attack_buffer_time

func _physics_process(delta: float) -> void:
	if _g == null:
		return
	if not _g.is_alive() or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		clear_input()
		return
	_g.human_movement = true
	var camera_yaw := _camera_yaw()
	var stick := Input.get_vector("g_left", "g_right", "g_forward", "g_back")
	_g.intent_move_world = Vector3(stick.x, 0.0, stick.y).rotated(Vector3.UP, camera_yaw)
	_g.intent_block = Input.is_action_pressed("g_block")
	_g.intent_revive = Input.is_action_pressed("g_revive")
	var aim := _g.intent_block or _queued_attack >= 0 or _g.action_lock > 0.0
	if aim:
		_g.intent_facing_yaw = camera_yaw
	elif stick.length_squared() > 0.001:
		_g.intent_facing_yaw = atan2(-_g.intent_move_world.x, -_g.intent_move_world.z)
	else:
		_g.intent_facing_yaw = _g.global_rotation.y
	_g.intent_move = 0.0
	_g.intent_turn = 0.0
	_g.intent_sword = _queued_attack == Gladiator.AttackType.SWORD
	_g.intent_kick = _queued_attack == Gladiator.AttackType.KICK
	_buffer_left = maxf(0.0, _buffer_left - delta)
	if _buffer_left <= 0.0:
		_queued_attack = -1

func clear_input() -> void:
	_queued_attack = -1
	_buffer_left = 0.0
	if not is_instance_valid(_g):
		return
	_g.human_movement = false
	_g.intent_move_world = Vector3.ZERO
	_g.intent_move = 0.0
	_g.intent_turn = 0.0
	_g.intent_sword = false
	_g.intent_kick = false
	_g.intent_block = false
	_g.intent_revive = false

func _on_attack_started(kind: int) -> void:
	if kind == _queued_attack:
		_queued_attack = -1
		_buffer_left = 0.0

func _on_revived(_health: float) -> void:
	clear_input()

func _camera_yaw() -> float:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return _g.global_rotation.y
	var rig := camera.get_parent()
	if rig != null and rig.has_method("get_yaw"):
		return rig.get_yaw()
	return camera.global_rotation.y

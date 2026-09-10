extends AnimationPlayer
## Shared animation clock for mechanics and procedural pose sampling.
## Method tracks enqueue events; dispatch after advance() permits safe parry /
## death cancellation without modifying AnimationPlayer inside its callbacks.

var running := false
var duration := 1.0
var windup_end := 0.3
var active_end := 0.5
var combo_start := 0.8
var cursor := 0.0
var _generation := 0
var _events: Array[StringName] = []
static var _libraries: Dictionary = {}
var _configuration := Vector3(-1, -1, -1)

func _init() -> void:
	name = "CombatAnimation"
	root_node = NodePath(".")
	callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	callback_mode_method = AnimationMixer.ANIMATION_CALLBACK_MODE_METHOD_IMMEDIATE

func configure(windup: float, active_hit: float, recovery: float) -> void:
	cancel()
	duration = maxf(windup + active_hit + recovery, 0.01)
	windup_end = windup / duration
	active_end = (windup + active_hit) / duration
	combo_start = lerpf(active_end, 1.0, 0.65)
	var key := Vector3(windup, active_hit, recovery)
	if key == _configuration:
		return
	_configuration = key
	if not _libraries.has(key):
		var clip := Animation.new()
		clip.length = 1.0
		var track := clip.add_track(Animation.TYPE_METHOD)
		clip.track_set_path(track, NodePath("."))
		for event in [[windup_end, &"EnableHitbox"], [active_end, &"DisableHitbox"],
				[combo_start, &"ResetComboWindow"], [1.0, &"FinishAttack"]]:
			clip.track_insert_key(track, event[0], {"method": &"_queue_event", "args": [event[1]]})
		var library := AnimationLibrary.new()
		library.add_animation(&"attack", clip)
		_libraries[key] = library
	if has_animation_library(&""):
		remove_animation_library(&"")
	add_animation_library(&"", _libraries[key])

func begin() -> void:
	cancel()
	cursor = 0.0
	running = true
	play(&"attack")
	advance(0.0)

func step(delta: float, playback_speed: float) -> void:
	if not running:
		return
	var generation := _generation
	advance(maxf(delta, 0.0) * maxf(playback_speed, 0.1) / duration)
	cursor = current_animation_position
	for event in _events:
		if generation != _generation:
			break
		get_parent().call(event)
	_events.clear()

func cancel() -> void:
	running = false
	_generation += 1
	stop()
	# Events already being dispatched are invalidated by generation, not erased.

func _queue_event(event: StringName) -> void:
	_events.append(event)

func phase_progress(start: float, finish: float) -> float:
	return clampf((cursor - start) / maxf(finish - start, 0.001), 0.0, 1.0)

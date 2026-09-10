extends RefCounted
## Analytic two-link legs: feet follow a ground-contact arc, knees fold
## only during swing, and reversing/strafe use the actual local velocity.

static func leg(hip: Node3D, knee: Node3D, phase: float, amount: float,
		local_direction: Vector3, upper: float, lower: float, body_y: float,
		limp := 1.0, stride := 0.25) -> void:
	# sin(phase) > 0 is the lifted half of the stride: move the foot
	# from behind the body to ahead of it, then return during ground contact.
	var travel := -cos(phase) * stride * amount
	var lift := maxf(0.0, sin(phase)) * 0.13 * amount * limp
	var target := Vector3(local_direction.x * travel, -(upper + lower - 0.012) + lift - body_y,
		local_direction.z * travel)
	# Work in the leg's sagittal plane after a small lateral hip rotation.
	hip.rotation.z = atan2(target.x, -target.y)
	var vertical := sqrt(target.y * target.y + target.x * target.x)
	var distance := clampf(Vector2(vertical, target.z).length(), absf(upper - lower) + 0.001, upper + lower - 0.001)
	var bend := PI - acos(clampf((upper * upper + lower * lower - distance * distance) / (2.0 * upper * lower), -1, 1))
	var offset := acos(clampf((upper * upper + distance * distance - lower * lower) / (2.0 * upper * distance), -1, 1))
	hip.rotation.x = atan2(-target.z, vertical) + offset
	hip.rotation.y = 0.0
	knee.rotation.x = -bend
	knee.get_node("Foot").rotation.x = -hip.rotation.x - knee.rotation.x + lift * 1.6

static func weight(delta: float, rate := 12.0) -> float:
	return 1.0 - exp(-maxf(delta, 0.0) * rate)


## Two-bone arm IK. The pole keeps the elbow outside the rib cage;
## unreachable targets are clamped rather than stretching the forearm.
static func arm(shoulder: Node3D, elbow: Node3D, target: Vector3,
		pole: Vector3, amount: float, upper := 0.33, lower := 0.335) -> void:
	var offset := target - shoulder.position
	var distance := clampf(offset.length(), absf(upper - lower) + 0.01, upper + lower - 0.005)
	var direction := offset.normalized()
	var bend_dir := (pole - direction * pole.dot(direction)).normalized()
	if direction.is_zero_approx() or bend_dir.is_zero_approx():
		return
	var angle := acos(clampf((upper * upper + distance * distance - lower * lower) / (2 * upper * distance), -1, 1))
	var upper_dir := direction * cos(angle) - bend_dir * sin(angle)
	var x := direction.cross(bend_dir).normalized()
	var y := -upper_dir
	var desired := Basis(x, y, x.cross(y)).orthonormalized()
	shoulder.quaternion = shoulder.quaternion.slerp(desired.get_rotation_quaternion(), amount)
	var bend := PI - acos(clampf((upper * upper + lower * lower - distance * distance) / (2 * upper * lower), -1, 1))
	elbow.rotation.x = lerpf(elbow.rotation.x, bend, amount)

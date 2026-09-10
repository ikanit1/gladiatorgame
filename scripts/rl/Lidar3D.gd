class_name Lidar3D
extends Node3D

## Круговой лидар из RayCast3D. Один экземпляр = один "канал" восприятия
## (враги отдельно, стены отдельно) - разделять каналы важнее, чем экономить
## размерность: иначе агент вынужден сам выучивать, что за объект он видит.
##
## ОПТИМИЗАЦИЯ: лучи создаются с enabled = false и обновляются вручную через
## force_raycast_update() только в момент сбора наблюдений. Включённый RayCast3D
## пересчитывается КАЖДЫЙ физический кадр - при 32 лучах и сотне арен это
## тысячи лишних запросов в секунду на данные, которые никто не читает.

@export var ray_count: int = 16
@export var ray_length: float = 12.0
@export var layer_mask: int = 4          ## 4 = "Enemy", 1 = "World"
@export var height: float = 0.9          ## высота, с которой смотрим

var _rays: Array[RayCast3D] = []
var _values: PackedFloat32Array


func _ready() -> void:
	position.y = height
	_values.resize(ray_count)
	_build_rays()


func _build_rays() -> void:
	for i in ray_count:
		var ray := RayCast3D.new()
		ray.enabled = false                      # не тикает вхолостую
		ray.collision_mask = layer_mask
		ray.collide_with_areas = false
		ray.collide_with_bodies = true

		# i = 0 смотрит строго вперёд (-Z), дальше по часовой стрелке
		var angle := TAU * float(i) / float(ray_count)
		ray.target_position = Vector3(sin(angle), 0.0, -cos(angle)) * ray_length

		add_child(ray)
		_rays.append(ray)


## Возвращает вектор длины ray_count в диапазоне 0..1.
## 0 = пусто, 1 = объект вплотную. Инверсия намеренная: "ничего не вижу"
## должно быть нулём, иначе на пустой арене вход в сеть - сплошные единицы.
func sense() -> PackedFloat32Array:
	for i in ray_count:
		var ray := _rays[i]
		ray.force_raycast_update()
		if ray.is_colliding():
			var d := ray.global_position.distance_to(ray.get_collision_point())
			_values[i] = clampf(1.0 - d / ray_length, 0.0, 1.0)
		else:
			_values[i] = 0.0
	return _values


## Тело-владельца надо исключить, иначе лучи "врагов" ловят самого гладиатора,
## если тот попадёт в чужую маску.
func exclude_body(body: CollisionObject3D) -> void:
	for ray in _rays:
		ray.add_exception(body)

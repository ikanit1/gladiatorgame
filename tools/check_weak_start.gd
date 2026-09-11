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

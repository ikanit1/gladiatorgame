extends SceneTree


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var r := TestReport.new("Chest")
	var scene: PackedScene = load("res://scenes/Chest.tscn")
	r.check(scene != null, "сцена сундука загружается")
	if scene == null:
		r.finish(self)
		return

	var state := RunState.new()

	var common: Chest = scene.instantiate()
	root.add_child(common)
	common.global_position = Vector3(4.0, 0.0, -2.0)
	common.setup(Chest.Kind.COMMON)
	r.check(not common.requires_key(), "обычный сундук без ключа")
	r.check(common.can_open(state, common.global_position), "обычный открывается вплотную")
	r.check(not common.can_open(state, common.global_position + Vector3(10.0, 0.0, 0.0)),
		"издалека не открывается")
	r.check(common.open(state, common.global_position), "открылся")
	r.check(common.is_open(), "помечен открытым")
	r.check(not common.open(state, common.global_position), "второй раз не открывается")

	var common_lid := common.get_node("Lid") as MeshInstance3D
	r.in_range(common_lid.rotation_degrees.x, -80.01, -79.99,
		"крышка открытого сундука откинута")
	common.setup(Chest.Kind.BOSS)
	r.check(not common.is_open(), "setup сбрасывает открытое состояние")
	r.eq(common_lid.rotation_degrees.x, 0.0, "setup закрывает крышку")
	r.check(common.can_open(state, common.global_position), "после setup сундук снова доступен")
	common.free()

	var locked: Chest = scene.instantiate()
	root.add_child(locked)
	locked.global_position = Vector3(-3.0, 0.0, 1.0)
	locked.setup(Chest.Kind.LOCKED)
	var opened_kinds: Array[int] = []
	locked.opened.connect(func(opened_kind: int) -> void: opened_kinds.append(opened_kind))
	r.check(locked.requires_key(), "запертый требует ключ")
	r.eq(state.keys, 1, "ключ пока на месте")
	r.check(locked.open(state, locked.global_position), "с ключом открылся")
	r.eq(state.keys, 0, "ключ списался")
	r.eq(opened_kinds.size(), 1, "opened испущен один раз")
	r.eq(opened_kinds[0], Chest.Kind.LOCKED, "opened сообщает вид сундука")
	r.check(not locked.open(state, locked.global_position), "повторное открытие отклонено")
	r.eq(state.keys, 0, "повторное открытие не списывает ключ")
	r.eq(opened_kinds.size(), 1, "повторное открытие не испускает opened")
	locked.free()

	var locked2: Chest = scene.instantiate()
	root.add_child(locked2)
	locked2.setup(Chest.Kind.LOCKED)
	r.check(not locked2.can_open(state, locked2.global_position), "без ключа не открывается")
	r.check(not locked2.open(state, locked2.global_position), "без ключа open возвращает false")
	locked2.free()

	r.finish(self)

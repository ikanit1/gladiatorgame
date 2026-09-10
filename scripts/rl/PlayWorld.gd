extends Node3D

## Сцена просмотра: одна арена с включённой графикой, камерой и HUD,
## но управляет гладиатором обученная политика, а не клавиатура.
##
## Sync ждёт `await get_parent().ready`, поэтому контроллер можно спокойно
## цеплять здесь - к моменту, когда Sync начнёт собирать группу "AGENT",
## узел уже будет в дереве.

@export var arena_path: NodePath = ^"Arena"

const CONTROLLER := preload("res://scripts/rl/GladiatorAIController.gd")


func _ready() -> void:
	var arena := get_node_or_null(arena_path) as Arena
	if arena == null:
		push_error("PlayWorld: арена не найдена по пути " + str(arena_path))
		return

	var ctrl := CONTROLLER.new()
	ctrl.name = "AIController"
	ctrl.brain_path = ^"../Brain"
	arena.gladiator.add_child(ctrl)

	print("PlayWorld: гладиатором управляет обученная политика")

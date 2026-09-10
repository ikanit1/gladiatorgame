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

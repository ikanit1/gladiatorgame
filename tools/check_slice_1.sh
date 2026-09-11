#!/usr/bin/env bash
# Прогон всех проверок среза 1. Любая упавшая проверка валит весь скрипт.
set -u

# Путь считается от самого скрипта, а не захардкожен: срез живёт в отдельном
# worktree, и фиксированный D:/AIfight прогонял бы проверки по чужой ветке.
# pwd -W нужен ради Godot: Windows-сборка не понимает путей вида /d/AIfight.
PROJECT=$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })
GODOT="${GODOT:-C:/Users/admin/Desktop/Godot_v4.6.3-stable_win64.exe}"
failed=0

if [ ! -x "$GODOT" ]; then
	echo "Godot не найден: $GODOT"
	echo "Передайте путь через переменную GODOT."
	exit 1
fi

run_script() {
	echo "=== $1 ==="
	"$GODOT" --headless --path "$PROJECT" --script "res://tools/$1"
	if [ $? -ne 0 ]; then
		echo "ПРОВАЛ: $1"
		failed=1
	fi
}

run_scene() {
	echo "=== $1 ==="
	"$GODOT" --headless --path "$PROJECT" "res://tools/$1"
	if [ $? -ne 0 ]; then
		echo "ПРОВАЛ: $1"
		failed=1
	fi
}

echo "проект: $PROJECT"
echo

# Новые проверки среза
run_script check_threat_curve.gd
run_script check_floor_plan.gd
run_script check_room_geometry.gd
run_script check_dungeon_room_doors.gd
run_script check_run_state.gd
run_script check_chest.gd
run_script check_upgrades.gd
run_script check_weak_start.gd
run_script check_arena_encounter.gd
run_scene  check_dungeon_floor.tscn
run_scene  check_game_floor.tscn

# Существующие проверки обязаны остаться зелёными
run_script check_combat_animation.gd
run_scene  check_enemy_bars.tscn
run_scene  check_variants.tscn
run_scene  check_ceiling_gate.tscn

echo
if [ "$failed" -eq 0 ]; then
	echo "ВСЁ ЗЕЛЁНОЕ"
else
	echo "ЕСТЬ ПРОВАЛЫ"
fi
exit "$failed"

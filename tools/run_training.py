"""Запуск обучения без графической панели.

Повторяет ту же последовательность, что и training/dashboard.py: сначала
поднимается Python-сервер, и только после его готовности подключается Godot.
Обратный порядок ломает рукопожатие - Godot стучится в ещё не открытый порт
и молча завершается.

Запуск:
    python tools/run_training.py --experiment gladiator_team_v5 --timesteps 1500000

Вывод дублируется в training/runs/<эксперимент>/train.log, чтобы за прогоном
можно было следить из другого окна.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
GODOT_DEFAULT = r"C:\Users\admin\Desktop\Godot_v4.6.3-stable_win64.exe"

# Строка, по которой видно, что сервер готов принимать подключение.
READY_MARK = "waiting for remote GODOT"


def build_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--experiment", default="gladiator_team_v5")
    p.add_argument("--timesteps", type=int, default=1_500_000)
    p.add_argument("--speedup", type=int, default=8)
    p.add_argument("--godot", default=os.environ.get("GODOT_BIN", GODOT_DEFAULT))
    p.add_argument("--scene", default="res://scenes/Training.tscn")
    return p.parse_args()


def main() -> int:
    args = build_args()
    logdir = ROOT / "training" / "runs" / args.experiment
    logdir.mkdir(parents=True, exist_ok=True)
    log_path = logdir / "train.log"

    if not pathlib.Path(args.godot).exists():
        print(f"не найден Godot: {args.godot}", flush=True)
        return 1

    cmd = [
        sys.executable, "-u", str(ROOT / "training" / "train_ppo.py"),
        "--connect",
        "--timesteps", str(args.timesteps),
        "--speedup", str(args.speedup),
        "--experiment", args.experiment,
    ]
    print("$ " + " ".join(cmd[1:]), flush=True)

    py = subprocess.Popen(
        cmd, cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, encoding="utf-8", errors="replace", bufsize=1)

    ready = threading.Event()
    godot: list = [None]

    def pump() -> None:
        with open(log_path, "w", encoding="utf-8") as log:
            for line in py.stdout:
                line = line.rstrip()
                if not line:
                    continue
                log.write(line + "\n")
                log.flush()
                if READY_MARK in line:
                    ready.set()
                print(line, flush=True)

    t = threading.Thread(target=pump, daemon=True)
    t.start()

    # Ждём готовности сервера, но не бесконечно: если train_ppo.py упал на
    # импорте, ждать его подключения бессмысленно.
    deadline = time.time() + 120
    while time.time() < deadline and not ready.is_set():
        if py.poll() is not None:
            print("Python завершился до готовности сервера", flush=True)
            return py.returncode or 1
        time.sleep(0.3)

    if not ready.is_set():
        print("сервер не поднялся за 120 секунд", flush=True)
        py.terminate()
        return 1

    gcmd = [args.godot, "--path", str(ROOT), "--headless", args.scene,
            f"--speedup={args.speedup}"]
    print("$ godot " + args.scene, flush=True)
    godot[0] = subprocess.Popen(
        gcmd, cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    code = py.wait()
    t.join(timeout=10)

    # Godot сам не выходит, когда Python закрывает соединение
    if godot[0] is not None and godot[0].poll() is None:
        godot[0].terminate()
        try:
            godot[0].wait(timeout=15)
        except subprocess.TimeoutExpired:
            godot[0].kill()

    print(f"обучение завершено, код {code}", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())

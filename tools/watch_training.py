"""Разреженное наблюдение за прогоном обучения.

Печатает строку не чаще, чем раз в step_mark шагов, плюс любые признаки
падения. Нужен потому, что SB3 выводит таблицу на каждый роллаут - при
полутора миллионах шагов это семьсот с лишним сообщений, в которых
настоящая ошибка потерялась бы.

Запуск:
    python tools/watch_training.py --experiment gladiator_team_v5
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent

NUM = re.compile(r"([-+]?\d+(?:\.\d+)?(?:e[-+]?\d+)?)")
FAIL = re.compile(r"Traceback|Error|FAILED|assert|Killed|OOM|not connected|refused",
                  re.IGNORECASE)


def value_of(line: str) -> float | None:
    m = NUM.search(line.split("|")[2]) if line.count("|") >= 3 else None
    return float(m.group(1)) if m else None


def build_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--experiment", default="gladiator_team_v5")
    p.add_argument("--step_mark", type=int, default=250_000,
                   help="Через сколько шагов печатать очередную сводку.")
    p.add_argument("--total", type=int, default=1_500_000,
                   help="Всего шагов в прогоне - нужно для оценки остатка.")
    p.add_argument("--poll", type=float, default=20.0)
    return p.parse_args()


def main() -> int:
    args = build_args()
    log = ROOT / "training" / "runs" / args.experiment / "train.log"

    started = time.time()
    next_mark = args.step_mark
    steps = 0
    reward = float("nan")
    fps = float("nan")
    elapsed_s = 0.0
    pos = 0

    while True:
        if not log.exists():
            time.sleep(args.poll)
            continue

        with open(log, "r", encoding="utf-8", errors="replace") as f:
            f.seek(pos)
            chunk = f.read()
            pos = f.tell()

        for line in chunk.splitlines():
            if FAIL.search(line):
                print("СБОЙ: " + line.strip(), flush=True)
                return 1
            if "обучение завершено" in line:
                print("готово: %d шагов, награда %.1f" % (steps, reward), flush=True)
                return 0
            # Имя поля берём из самой ячейки таблицы, а не поиском подстроки
            # вида "| fps": в выводе SB3 после палки идут четыре пробела,
            # и такая проверка молча не срабатывала - скорость оставалась nan,
            # а вместе с ней пропадала и оценка остатка.
            if line.count("|") < 3:
                continue
            field = line.split("|")[1].strip()
            v = value_of(line)
            if v is None:
                continue
            if field == "total_timesteps":
                steps = int(v)
            elif field == "ep_rew_mean":
                reward = v
            elif field == "fps":
                fps = v
            elif field == "time_elapsed":
                elapsed_s = v

        if steps >= next_mark:
            # Время берём из самого SB3: наблюдатель мог быть запущен позже
            # прогона, и его собственный секундомер занижал бы прошедшее.
            elapsed = elapsed_s if elapsed_s > 0 else (time.time() - started)
            left = ""
            if fps == fps and fps > 0 and args.total > steps:
                left = ", осталось ~%.0f мин" % ((args.total - steps) / fps / 60.0)
            print("%d шагов, награда %.1f, %.0f шаг/с, прошло %.0f мин%s" % (
                steps, reward, fps, elapsed / 60.0, left), flush=True)
            while next_mark <= steps:
                next_mark += args.step_mark

        time.sleep(args.poll)


if __name__ == "__main__":
    raise SystemExit(main())

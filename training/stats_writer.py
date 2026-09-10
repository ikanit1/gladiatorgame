"""
Callback, который выкладывает состояние обучения в JSON-файл.

Зачем файл, а не парсинг stdout: вывод SB3 форматируется таблицей и меняется
от версии к версии, парсить его хрупко. Файл читает любой наблюдатель
(дашборд, скрипт, второй терминал), и обучение от этого не зависит.
"""

import json
import pathlib
import time
from collections import deque

from stable_baselines3.common.callbacks import BaseCallback

# Поля боевой статистики, которые GladiatorBrain.get_stats() кладёт в info
COMBAT_KEYS = (
    "kills", "wave", "attacks", "sword", "kicks", "misses",
    "damage_dealt", "damage_taken", "blocks", "absorbed",
    "staggers", "guard_breaks", "idle_block", "potions", "healed",
)


class StatsWriter(BaseCallback):
    def __init__(self, path: pathlib.Path, mode: str = "training",
                 total_timesteps: int = 0, flush_every: float = 1.0):
        super().__init__()
        self.path = pathlib.Path(path)
        self.mode = mode
        self.total_timesteps = total_timesteps
        self.flush_every = flush_every

        self._t0 = time.time()
        self._last_write = 0.0
        self._episodes = 0
        self._reward_hist = deque(maxlen=400)
        self._combat_hist = deque(maxlen=50)
        self._last_combat: dict = {}

    # ------------------------------------------------------------------

    def _on_training_start(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._write(force=True)

    def _on_step(self) -> bool:
        # Боевую статистику агент отдаёт в info на каждом шаге; забираем её
        # только на завершённых эпизодах, иначе получим состояние "в моменте".
        infos = self.locals.get("infos") or []
        dones = self.locals.get("dones")
        if dones is None:
            dones = self.locals.get("done", [])

        for i, info in enumerate(infos):
            finished = bool(dones[i]) if i < len(dones) else False
            if not finished or not isinstance(info, dict):
                continue

            self._episodes += 1
            combat = {k: info[k] for k in COMBAT_KEYS if k in info}
            if combat:
                self._last_combat = combat
                self._combat_hist.append(combat)

            ep = info.get("episode")
            if isinstance(ep, dict) and "r" in ep:
                self._reward_hist.append(float(ep["r"]))

        if time.time() - self._last_write >= self.flush_every:
            self._write()
        return True

    def _on_training_end(self) -> None:
        self._write(force=True, finished=True)

    # ------------------------------------------------------------------

    def _avg_combat(self) -> dict:
        if not self._combat_hist:
            return {}
        keys = set()
        for c in self._combat_hist:
            keys |= set(c.keys())
        out = {}
        for k in keys:
            vals = [float(c[k]) for c in self._combat_hist if k in c]
            if vals:
                out[k] = sum(vals) / len(vals)
        return out

    def _write(self, force: bool = False, finished: bool = False) -> None:
        self._last_write = time.time()
        elapsed = max(self._last_write - self._t0, 1e-6)
        steps = int(self.num_timesteps)

        rewards = list(self._reward_hist)
        recent = rewards[-20:] if rewards else []

        payload = {
            "mode": self.mode,
            "finished": finished,
            "timesteps": steps,
            "total_timesteps": self.total_timesteps,
            "iterations": int(self.model.__dict__.get("_n_updates", 0) or 0),
            "episodes": self._episodes,
            "elapsed_sec": round(elapsed, 1),
            "fps": round(steps / elapsed, 1),
            "reward_mean": round(sum(recent) / len(recent), 2) if recent else None,
            "reward_best": round(max(rewards), 2) if rewards else None,
            "reward_curve": [round(r, 2) for r in rewards],
            "combat_last": self._last_combat,
            "combat_avg": {k: round(v, 2) for k, v in self._avg_combat().items()},
            "updated": self._last_write,
        }

        # Пишем через временный файл: дашборд не должен поймать половину JSON
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.path)


def write_play_stats(path: pathlib.Path, episodes: list, running: bool = True) -> None:
    """Тот же формат для режима просмотра - дашборд не различает источники."""
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    rewards = [e["reward"] for e in episodes]
    recent = rewards[-20:] if rewards else []
    last = episodes[-1]["combat"] if episodes else {}

    avg = {}
    if episodes:
        keys = set()
        for e in episodes:
            keys |= set(e["combat"].keys())
        for k in keys:
            vals = [float(e["combat"][k]) for e in episodes if k in e["combat"]]
            if vals:
                avg[k] = round(sum(vals) / len(vals), 2)

    payload = {
        "mode": "play",
        "finished": not running,
        "timesteps": 0,
        "total_timesteps": 0,
        "iterations": 0,
        "episodes": len(episodes),
        "elapsed_sec": 0,
        "fps": 0,
        "reward_mean": round(sum(recent) / len(recent), 2) if recent else None,
        "reward_best": round(max(rewards), 2) if rewards else None,
        "reward_curve": [round(r, 2) for r in rewards],
        "combat_last": last,
        "combat_avg": avg,
        "updated": time.time(),
    }
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)

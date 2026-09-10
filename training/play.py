"""
Просмотр обученной политики: Python думает, Godot показывает.

Запускать в таком порядке:
    python -u training/play.py
    godot --path D:/AIfight res://scenes/Play.tscn

ONNX-инференс прямо внутри Godot здесь не используется намеренно: обёртка
плагина написана на C# и требует .NET-сборки Godot. С обычной сборкой
единственный рабочий путь - тот же TCP-мост, что и при обучении.
"""

import argparse
import pathlib

from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv
from stable_baselines3 import PPO
from stable_baselines3.common.vec_env import VecMonitor, VecNormalize

import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from stats_writer import write_play_stats

ROOT = pathlib.Path(__file__).resolve().parent.parent


def build_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--experiment", default="gladiator_ppo")
    p.add_argument("--model", default=None, help="Путь к .zip (по умолчанию gladiator_final.zip)")
    p.add_argument("--episodes", type=int, default=0, help="0 = играть бесконечно")
    p.add_argument("--speedup", type=int, default=1)
    p.add_argument("--stochastic", action="store_true",
                   help="Сэмплировать действия вместо среднего - агент выглядит живее, но дёргается.")
    return p.parse_args()


def main() -> None:
    args = build_args()
    logdir = ROOT / "training" / "runs" / args.experiment
    model_path = pathlib.Path(args.model) if args.model else logdir / "gladiator_final.zip"

    if not model_path.exists():
        raise SystemExit(f"Модель не найдена: {model_path}")

    env = StableBaselinesGodotEnv(env_path=None, show_window=True,
                                  speedup=args.speedup, n_parallel=1, seed=0)

    # Цепочка обёрток обязана совпадать с обучением. Плюс godot-rl 0.8.2
    # рассчитан на SB3 <= 2.4: у его env нет атрибута render_mode, который
    # VecNormalize.load требует напрямую. VecMonitor его добавляет.
    env = VecMonitor(env)

    vecnorm = logdir / "vecnormalize.pkl"
    if vecnorm.exists():
        # Та же статистика, что при обучении. Без неё политика видит другой
        # масштаб величин и ведёт себя как необученная.
        env = VecNormalize.load(str(vecnorm), env)
        env.training = False        # не обновлять статистику при просмотре
        env.norm_reward = False     # награда нужна только для печати
        print(f"Загружена нормализация из {vecnorm}")

    model = PPO.load(str(model_path))

    # Пространства сверяем явно. Без этой проверки несовместимая модель падает
    # где-то в недрах предсказания с сообщением про формы тензоров, по которому
    # причину не угадать. А ломается это легко: любое изменение набора
    # наблюдений (с добавлением зелий вектор вырос с 46 до 50) делает
    # все прежние модели непригодными.
    if model.observation_space != env.observation_space:
        raise SystemExit("\n".join([
            f"Модель {model_path.name} обучена на другом наборе наблюдений.",
            f"  в модели: {model.observation_space}",
            f"  в игре:   {env.observation_space}",
            "Механика с тех пор изменилась — нужно обучить заново:",
            "впиши в панели новое имя эксперимента и нажми «Обучать».",
        ]))
    print(f"Загружена модель {model_path}")

    obs = env.reset()
    ep = 0
    ep_reward = 0.0
    history = []
    # ОТДЕЛЬНЫЙ файл: режим просмотра писал в live_stats.json и затирал
    # статистику обучения того же эксперимента.
    stats_path = logdir / "live_play.json"
    write_play_stats(stats_path, history)

    try:
        while args.episodes == 0 or ep < args.episodes:
            action, _ = model.predict(obs, deterministic=not args.stochastic)
            obs, reward, done, info = env.step(action)
            ep_reward += float(reward[0])

            if done[0]:
                ep += 1
                stats = info[0] if info else {}
                history.append({"reward": ep_reward,
                                "combat": {k: v for k, v in stats.items()
                                           if isinstance(v, (int, float))}})
                write_play_stats(stats_path, history)
                print("эпизод %d | награда %.1f | убито %s | волна %s | "
                      "ударов %s, мимо %s (%.0f%%) | щит вхолостую %s шагов" % (
                          ep, ep_reward, stats.get("kills", "?"), stats.get("wave", "?"),
                          stats.get("attacks", "?"), stats.get("misses", "?"),
                          100.0 * float(stats.get("miss_rate", 0.0)),
                          stats.get("idle_block", "?")))
                ep_reward = 0.0
    except KeyboardInterrupt:
        print("\nостановлено")
    finally:
        write_play_stats(stats_path, history, running=False)
        env.close()


if __name__ == "__main__":
    main()

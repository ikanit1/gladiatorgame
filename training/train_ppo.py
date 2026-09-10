"""
Обучение гладиатора алгоритмом PPO (Stable-Baselines3) через godot_rl_agents.

Два режима запуска:

1. Подключение к запущенному Godot (удобно для отладки, видно происходящее):
       python training/train_ppo.py --connect
   и параллельно, ПОСЛЕ старта скрипта:
       godot --path D:/AIfight res://scenes/Training.tscn --speedup 8

2. Запуск экспортированной сборки (быстрее, для настоящего обучения):
       python training/train_ppo.py --env_path build/AIfight.exe --n_parallel 4
"""

import argparse
import pathlib

from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv
from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback
from stable_baselines3.common.vec_env import VecMonitor, VecNormalize

import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from stats_writer import StatsWriter

ROOT = pathlib.Path(__file__).resolve().parent.parent


def _tensorboard_available() -> bool:
    """SB3 падает на старте, если tensorboard_log задан, а пакета нет.
    Логи в TensorBoard - удобство, а не условие обучения."""
    import importlib.util
    return importlib.util.find_spec("tensorboard") is not None


def build_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--env_path", default=None,
                   help="Путь к экспортированной сборке игры. Без него скрипт ждёт подключения Godot.")
    p.add_argument("--connect", action="store_true",
                   help="Ждать подключения вручную запущенного Godot.")
    p.add_argument("--timesteps", type=int, default=2_000_000)
    p.add_argument("--n_parallel", type=int, default=1,
                   help="Сколько процессов Godot запускать (только с --env_path).")
    p.add_argument("--speedup", type=int, default=8,
                   help="Во сколько раз ускорять время в игре.")
    p.add_argument("--experiment", default="gladiator_ppo")
    p.add_argument("--resume", default=None, help="Путь к .zip для продолжения обучения.")
    return p.parse_args()


def main() -> None:
    args = build_args()
    logdir = ROOT / "training" / "runs" / args.experiment
    logdir.mkdir(parents=True, exist_ok=True)

    tb_log = str(logdir) if _tensorboard_available() else None
    if tb_log is None:
        print("tensorboard не установлен - метрики будут только в консоли "
              "(pip install tensorboard, чтобы включить графики)")

    env = StableBaselinesGodotEnv(
        env_path=args.env_path,
        show_window=False,
        speedup=args.speedup,
        n_parallel=args.n_parallel,
        seed=0,
    )

    # VecMonitor нужен, чтобы в логи попали ep_rew_mean и ep_len_mean.
    # Без него у PPO не будет ни одной осмысленной метрики.
    env = VecMonitor(env)

    # Наблюдения уже нормализованы внутри GladiatorBrain (всё в -1..1),
    # поэтому norm_obs выключен. А вот масштаб наград гуляет: убийство даёт +3,
    # штраф за шаг -0.0015. Без нормализации наград value loss разъезжается
    # на порядки и градиенты взрываются.
    vecnorm_path = logdir / "vecnormalize.pkl"
    if args.resume and vecnorm_path.exists():
        # ПОДВОХ: без загрузки старой статистики VecNormalize продолженное
        # обучение стартует с другим масштабом наград, и политика "забывает"
        # выученное на первых же обновлениях.
        env = VecNormalize.load(str(vecnorm_path), env)
        env.training = True
        env.norm_reward = True
        print(f"Загружена статистика нормализации из {vecnorm_path}")
    else:
        env = VecNormalize(env, norm_obs=False, norm_reward=True,
                           clip_reward=10.0, gamma=0.995)

    if args.resume:
        model = PPO.load(args.resume, env=env, tensorboard_log=tb_log)
        print(f"Продолжаем обучение с {args.resume}")
    else:
        model = PPO(
            # Именно MultiInputPolicy, а не MlpPolicy: godot_rl отдаёт
            # наблюдения словарём {"obs": [...]}, а для словарного пространства
            # наблюдений SB3 требует политику с MultiInput-экстрактором.
            "MultiInputPolicy",
            env,
            verbose=1,
            tensorboard_log=tb_log,

            # На одно решение приходится action_repeat = 8 физических шагов,
            # то есть ~7.5 решений в секунду игрового времени.
            n_steps=64,          # шагов на окружение до обновления
            batch_size=256,
            n_epochs=10,

            # gamma 0.995 при 7.5 решений/сек даёт горизонт около 25 секунд -
            # примерно длина эпизода. При 0.99 агент перестаёт видеть
            # последствия дальше 13 секунд и начинает жадно лезть в толпу.
            gamma=0.995,
            gae_lambda=0.95,

            learning_rate=3e-4,
            clip_range=0.2,
            # Без энтропийного бонуса PPO на непрерывных действиях быстро
            # схлопывается в одну стратегию (обычно "бежать вперёд и спамить меч")
            # и перестаёт пробовать блок и пинок.
            ent_coef=0.005,
            vf_coef=0.5,
            max_grad_norm=0.5,

            policy_kwargs=dict(net_arch=dict(pi=[256, 256], vf=[256, 256])),
        )

    stats = StatsWriter(logdir / "live_stats.json", mode="training",
                        total_timesteps=args.timesteps)

    checkpoint = CheckpointCallback(
        save_freq=max(20_000 // max(args.n_parallel, 1), 1),
        save_path=str(logdir / "checkpoints"),
        name_prefix="gladiator",
    )

    try:
        model.learn(total_timesteps=args.timesteps, callback=[checkpoint, stats],
                    tb_log_name="ppo")
    finally:
        model.save(str(logdir / "gladiator_final"))
        # ВАЖНО: статистику VecNormalize надо сохранять вместе с моделью.
        # Без неё при инференсе награды/наблюдения масштабируются иначе,
        # и обученная политика ведёт себя как случайная.
        env.save(str(logdir / "vecnormalize.pkl"))
        env.close()
        print(f"Сохранено в {logdir}")


if __name__ == "__main__":
    main()

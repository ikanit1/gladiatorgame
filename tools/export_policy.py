"""
Выгрузка обученной политики в бинарный файл, который читает Godot.

Зачем: ONNX-обёртка godot_rl_agents написана на C# и требует .NET-сборки
Godot. С обычной сборкой единственным способом «оживить» агента в игре
оставался запущенный рядом Python. Но сеть политики крошечная
(50 -> 256 -> 256 -> 5, Tanh), и её forward считается прямо в GDScript
за доли миллисекунды. Так ИИ-напарник работает в игре автономно.

Берём только ветку политики: value_net нужен обучению, а не игре.
При deterministic-инференсе действие = выход action_net, обрезанный до [-1, 1],
поэтому log_std тоже не нужен.

Запуск:
    python tools/export_policy.py --experiment gladiator_v4
Результат: models/<эксперимент>.policy
"""

import argparse
import pathlib
import struct

import numpy as np
from stable_baselines3 import PPO

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAGIC = b"GLADPOL1"
ACT_NONE, ACT_TANH = 0, 1


def build_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--experiment", default="gladiator_v4")
    p.add_argument("--model", default=None)
    p.add_argument("--out", default=None)
    p.add_argument("--samples", type=int, default=8,
                   help="Сколько контрольных пар obs->action записать для сверки.")
    return p.parse_args()


def main() -> None:
    args = build_args()
    logdir = ROOT / "training" / "runs" / args.experiment
    model_path = pathlib.Path(args.model) if args.model else logdir / "gladiator_final.zip"
    if not model_path.exists():
        raise SystemExit(f"Модель не найдена: {model_path}")

    model = PPO.load(str(model_path), device="cpu")
    policy = model.policy

    obs_dim = int(model.observation_space["obs"].shape[0])
    act_dim = int(model.action_space.shape[0])

    def np_of(name: str) -> np.ndarray:
        return policy.state_dict()[name].detach().cpu().numpy().astype(np.float32)

    layers = [
        (np_of("mlp_extractor.policy_net.0.weight"),
         np_of("mlp_extractor.policy_net.0.bias"), ACT_TANH),
        (np_of("mlp_extractor.policy_net.2.weight"),
         np_of("mlp_extractor.policy_net.2.bias"), ACT_TANH),
        (np_of("action_net.weight"), np_of("action_net.bias"), ACT_NONE),
    ]

    out_path = pathlib.Path(args.out) if args.out else ROOT / "models" / f"{args.experiment}.policy"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with open(out_path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<iii", obs_dim, act_dim, len(layers)))
        for w, b, act in layers:
            out_dim, in_dim = w.shape
            f.write(struct.pack("<iii", in_dim, out_dim, act))
            # Порядок строк: веса нейрона o лежат подряд - так GDScript читает
            # их последовательно, без прыжков по памяти.
            f.write(w.astype("<f4").tobytes())
            f.write(b.astype("<f4").tobytes())

        # Контрольные примеры: по ним Godot проверяет, что его forward
        # совпадает с PyTorch. Без сверки расхождение всплыло бы только
        # как «агент играет странно», и искать причину пришлось бы наугад.
        rng = np.random.default_rng(0)
        samples = rng.uniform(-1.0, 1.0, size=(args.samples, obs_dim)).astype(np.float32)
        actions, _ = model.predict({"obs": samples}, deterministic=True)
        actions = np.asarray(actions, dtype=np.float32).reshape(args.samples, act_dim)

        f.write(struct.pack("<i", args.samples))
        f.write(samples.astype("<f4").tobytes())
        f.write(actions.astype("<f4").tobytes())

    size_kb = out_path.stat().st_size / 1024
    print(f"Записано: {out_path}  ({size_kb:.0f} КБ)")
    print(f"  наблюдений {obs_dim}, действий {act_dim}, слоёв {len(layers)}")
    print(f"  контрольных пар: {args.samples}")
    print("  пример действия:", np.round(actions[0], 4))


if __name__ == "__main__":
    main()

"""
Процедурная генерация звуков для арены.

Зачем синтез, а не готовые сэмплы: ноль внешних зависимостей и лицензий,
звуки правятся параметром в коде, а весь набор весит десятки килобайт.

Запуск:  python tools/gen_sounds.py
Результат: audio/*.wav (22050 Гц, моно, 16 бит) - Godot импортирует их сам.
"""

import pathlib
import struct
import wave

import numpy as np

SR = 22050
OUT = pathlib.Path(__file__).resolve().parent.parent / "audio"
rng = np.random.default_rng(12345)


# ----------------------------------------------------------------------
# Примитивы синтеза
# ----------------------------------------------------------------------

def t(dur: float) -> np.ndarray:
    return np.linspace(0.0, dur, int(SR * dur), endpoint=False)


def noise(dur: float) -> np.ndarray:
    return rng.uniform(-1.0, 1.0, int(SR * dur))


def env_exp(x: np.ndarray, decay: float, attack: float = 0.002) -> np.ndarray:
    """Резкая атака + экспоненциальное затухание - основа любого удара."""
    n = len(x)
    e = np.exp(-np.linspace(0.0, decay, n))
    a = int(max(1, attack * SR))
    e[:a] *= np.linspace(0.0, 1.0, a)
    return x * e


def lowpass(x: np.ndarray, width: int) -> np.ndarray:
    """Скользящее среднее вместо БИХ-фильтра: scipy не нужен."""
    if width < 2:
        return x
    k = np.ones(width) / width
    return np.convolve(x, k, mode="same")


def highpass(x: np.ndarray, width: int) -> np.ndarray:
    return x - lowpass(x, width)


def sweep(dur: float, f0: float, f1: float) -> np.ndarray:
    """Синус с линейно едущей частотой."""
    tt = t(dur)
    f = np.linspace(f0, f1, len(tt))
    return np.sin(2.0 * np.pi * np.cumsum(f) / SR)


def metallic(dur: float, freqs, decay: float) -> np.ndarray:
    """Несгармоничные частоты = металл. Гармоничные звучали бы как флейта."""
    tt = t(dur)
    out = np.zeros(len(tt))
    for i, f in enumerate(freqs):
        out += np.sin(2.0 * np.pi * f * tt) * np.exp(-decay * (1.0 + i * 0.35) * tt)
    return out / len(freqs)


def mix(*layers) -> np.ndarray:
    """Складывает слои разной длины, выравнивая по самому длинному."""
    n = max(len(x) for x, _ in layers)
    out = np.zeros(n)
    for x, gain in layers:
        out[: len(x)] += x * gain
    return out


def save(name: str, x: np.ndarray, gain: float = 0.85) -> None:
    peak = np.max(np.abs(x)) or 1.0
    x = np.clip(x / peak * gain, -1.0, 1.0)
    data = (x * 32767).astype(np.int16)

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(struct.pack(f"<{len(data)}h", *data))
    print(f"  {path.name:22s} {len(data) / SR:.2f} c")


# ----------------------------------------------------------------------
# Сами звуки
# ----------------------------------------------------------------------

def sword_swing() -> np.ndarray:
    # Свист = узкополосный шум с едущей вверх-вниз полосой
    n = highpass(lowpass(noise(0.28), 12), 60)
    return env_exp(n, 7.0, 0.03)


def sword_hit() -> np.ndarray:
    # Лязг стали + глухой мясной удар
    steel = metallic(0.35, [1750, 2480, 3260, 4400], 16.0)
    flesh = env_exp(lowpass(noise(0.22), 45), 16.0)
    thump = env_exp(sweep(0.18, 190.0, 70.0), 12.0)
    return mix((steel, 0.55), (flesh, 0.5), (thump, 0.6))


def kick() -> np.ndarray:
    # Низкий тупой удар без металла
    thump = env_exp(sweep(0.26, 150.0, 45.0), 9.0)
    body = env_exp(lowpass(noise(0.2), 80), 14.0)
    return mix((thump, 0.9), (body, 0.35))


def shield_block() -> np.ndarray:
    # Звонкий удар в бронзу - самый заметный звук в бою
    ring = metallic(0.55, [980, 1470, 2210, 2990, 4130], 9.0)
    clank = env_exp(highpass(noise(0.12), 20), 26.0)
    return mix((ring, 0.8), (clank, 0.35))


def guard_break() -> np.ndarray:
    # Серия щелчков = трещит дерево щита
    out = np.zeros(int(SR * 0.5))
    for start, amp in [(0.0, 1.0), (0.045, 0.7), (0.085, 0.5), (0.14, 0.35)]:
        crack = env_exp(highpass(noise(0.12), 8), 30.0) * amp
        i = int(start * SR)
        out[i:i + len(crack)] += crack[: len(out) - i]
    low = env_exp(sweep(0.5, 220.0, 60.0), 6.0) * 0.4
    return mix((out, 1.0), (low, 1.0))


def player_hurt() -> np.ndarray:
    grunt = env_exp(lowpass(noise(0.25), 70), 12.0)
    tone = env_exp(sweep(0.22, 160.0, 110.0), 10.0)
    return mix((grunt, 0.6), (tone, 0.5))


def player_die() -> np.ndarray:
    fall = env_exp(sweep(0.9, 140.0, 40.0), 3.5)
    armor = env_exp(metallic(0.8, [820, 1240, 1910], 5.0), 2.0)
    return mix((fall, 0.7), (armor, 0.45))


def zombie_growl() -> np.ndarray:
    # Рычание = низкий шум с медленной амплитудной модуляцией
    n = lowpass(noise(0.75), 90)
    tt = t(0.75)
    am = 0.6 + 0.4 * np.sin(2.0 * np.pi * 7.0 * tt)
    body = n * am
    tone = np.sin(2.0 * np.pi * 95.0 * tt) * 0.3
    return env_exp(mix((body, 1.0), (tone, 1.0)), 2.2, 0.05)


def zombie_die() -> np.ndarray:
    tt = t(0.7)
    n = lowpass(noise(0.7), 100)
    am = 0.5 + 0.5 * np.sin(2.0 * np.pi * 5.0 * tt)
    wail = sweep(0.7, 180.0, 60.0) * 0.4
    return env_exp(mix((n * am, 1.0), (wail, 1.0)), 3.2, 0.02)


def wave_start() -> np.ndarray:
    # Гонг: длинное затухание и низкая основа
    gong = metallic(1.6, [196, 293, 441, 622, 880, 1170], 2.4)
    hit = env_exp(highpass(noise(0.08), 15), 30.0) * 0.3
    out = gong
    out[: len(hit)] += hit
    return out


def potion_pickup() -> np.ndarray:
    # Восходящая терция + звон стекла: должен читаться как "хорошее событие"
    # на фоне ударов, поэтому он единственный тональный и восходящий.
    tt = t(0.45)
    a = np.sin(2.0 * np.pi * 660.0 * tt) * np.exp(-9.0 * tt)
    b = np.sin(2.0 * np.pi * 880.0 * tt) * np.exp(-7.0 * tt)
    c = np.sin(2.0 * np.pi * 1320.0 * tt) * np.exp(-6.0 * tt)
    glass = env_exp(highpass(noise(0.12), 10), 28.0) * 0.25
    up = sweep(0.3, 520.0, 1250.0) * np.exp(-6.0 * t(0.3))
    return mix((a, 0.5), (b, 0.6), (c, 0.35), (up, 0.4), (glass, 1.0))


def potion_spawn() -> np.ndarray:
    # Тихий "динь" в момент появления - подсказка игроку, что на арене новое
    tt = t(0.5)
    bell = np.sin(2.0 * np.pi * 1480.0 * tt) * np.exp(-5.0 * tt)
    bell2 = np.sin(2.0 * np.pi * 2220.0 * tt) * np.exp(-7.0 * tt)
    return mix((bell, 0.6), (bell2, 0.3))


def footstep() -> np.ndarray:
    # Шаг по песку - короткий шорох
    return env_exp(highpass(lowpass(noise(0.12), 30), 200), 22.0, 0.004)


SOUNDS = {
    "sword_swing": (sword_swing, 0.55),
    "sword_hit": (sword_hit, 0.9),
    "kick": (kick, 0.85),
    "shield_block": (shield_block, 0.9),
    "guard_break": (guard_break, 0.9),
    "player_hurt": (player_hurt, 0.8),
    "player_die": (player_die, 0.9),
    "zombie_growl": (zombie_growl, 0.45),
    "zombie_die": (zombie_die, 0.7),
    "wave_start": (wave_start, 0.8),
    "footstep": (footstep, 0.3),
    "potion_pickup": (potion_pickup, 0.7),
    "potion_spawn": (potion_spawn, 0.35),
}


def main() -> None:
    print(f"Генерация в {OUT}")
    for name, (fn, gain) in SOUNDS.items():
        save(name, fn(), gain)
    print(f"Готово: {len(SOUNDS)} файлов")


if __name__ == "__main__":
    main()

"""Подготовка UI-ассетов из Higgsfield к использованию в Godot.

Иконки приходят из Recraft в режиме utility_vector, то есть готовым SVG.
Внутри каждого файла первый путь - чёрный прямоугольник во весь холст
(фон, заказанный через background_color), а всё после него - сам глиф.
Достаточно выбросить этот первый путь, и остаётся белая фигура на
прозрачном фоне: ни вырезания фона, ни кеинга по яркости не требуется.

Чёрные пути ПОСЛЕ фона трогать нельзя - это внутренняя деталь: умбон щита,
глазницы черепа, прорезь шлема. При перекраске глифа через modulate они
останутся тёмными и прочитаются как углубления, а не как дырки.

Размер задаётся атрибутами width/height, viewBox не меняется. Godot
растрирует SVG именно по width/height, поэтому иконка попадает в атлас уже
маленькой, а не мегабайтной текстурой 1024 на 1024.

Запуск:
    python tools/ui_assets.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Нужен Pillow: pip install pillow")

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "assets" / "higgsfield" / "ui" / "raw"
OUT = ROOT / "assets" / "ui"

# Иконки в интерфейсе рисуются 18-28 пикселей, эмблема меню - около 96.
# Двукратный запас нужен на мониторы с масштабированием.
ICON_PX = 64
EMBLEM_PX = 256

ICONS = ["helmet", "shield", "sword", "skull",
         "hourglass", "banner", "potion", "arch"]

# Полный холст: фон, который надо убрать. Совпадение проверяем по числам,
# а не по строке целиком - генератор может расставить пробелы иначе.
_FULL_CANVAS = re.compile(
    r"^M\s*0\s*0\s*L\s*(\d+)\s*0\s*L\s*\1\s*\1\s*L\s*0\s*\1\s*L\s*0\s*0\s*z\s*$")


def _is_background(tag: str) -> bool:
    """Чёрный путь во весь холст - это фон."""
    if 'fill="rgb(0,0,0)"' not in tag:
        return False
    d = re.search(r'd="([^"]*)"', tag)
    return bool(d and _FULL_CANVAS.match(d.group(1).strip()))


def strip_background(src: Path, dst: Path, px: int) -> None:
    svg = src.read_text(encoding="utf-8", errors="replace")

    removed = 0
    out: list[str] = []
    pos = 0
    for m in re.finditer(r"<path\b[^>]*/?>", svg):
        # Убираем только ПЕРВЫЙ подходящий путь. Если генератор нарисует
        # фон дважды, второй экземпляр всё равно перекрыт глифом, а вот
        # ошибочно снесённая крупная деталь испортила бы иконку молча.
        if removed == 0 and _is_background(m.group(0)):
            out.append(svg[pos:m.start()])
            pos = m.end()
            removed = 1
    out.append(svg[pos:])
    svg = "".join(out)

    if removed == 0:
        print(f"  ВНИМАНИЕ {src.name}: фоновый путь не найден, фон останется чёрным")

    svg = re.sub(r'\bwidth="\d+"', f'width="{px}"', svg, count=1)
    svg = re.sub(r'\bheight="\d+"', f'height="{px}"', svg, count=1)

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(svg, encoding="utf-8")
    print(f"  иконка  {dst.name:<16} {px}x{px}  фон убран: {'да' if removed else 'НЕТ'}")


def crop_and_shrink(src: Path, dst: Path, width: int, crop: bool,
                    height: int | None = None) -> None:
    """Обрезка по содержимому и уменьшение до размера, пригодного для UI.

    Генератор кладёт широкую рамку в кадр 16:9 и добивает пустотой сверху и
    снизу. Без обрезки эта пустота попала бы в nine-slice как часть краёв, и
    рамка растянулась бы вместе с ней.

    height задаётся отдельно от ширины намеренно. Nine-slice рисует кромку
    один к одному в пикселях текстуры: кант толщиной 18 пикселей физически
    не помещается в полосу здоровья высотой 22, и Godot в таком случае
    растягивает кромку на всю плашку, полностью закрывая заливку. Поэтому
    обойма полосы сжимается по вертикали сильнее, чем по горизонтали, пока
    кант не станет 4-5 пикселей.
    """
    img = Image.open(src).convert("RGB")
    if crop:
        # Порог низкий: внутренняя часть рамки почти чёрная и должна
        # остаться внутри рамки, а не быть срезанной вместе с полями.
        mask = img.convert("L").point(lambda v: 255 if v > 28 else 0)
        box = mask.getbbox()
        if box:
            img = img.crop(box)
            print(f"          обрезано до {img.width}x{img.height}")

    h = height if height else max(1, round(img.height * width / img.width))
    img = img.resize((width, h), Image.LANCZOS)
    dst.parent.mkdir(parents=True, exist_ok=True)
    img.save(dst, "PNG", optimize=True)
    print(f"  рамка   {dst.name:<16} {width}x{h}")


FRAMES = [
    # имя, ширина, обрезать ли по содержимому, высота (None - по пропорции)
    ("panel_frame", 256, False, None),  # рамка уже занимает весь кадр
    ("bar_frame", 256, True, 30),       # сжата по вертикали: см. crop_and_shrink
    ("menu_bg", 1920, False, None),
]


def main() -> int:
    if not RAW.exists():
        sys.exit(f"Нет каталога с исходниками: {RAW}")

    print("Иконки (SVG, снятие фонового прямоугольника):")
    for name in ICONS + ["emblem"]:
        src = RAW / f"{name}.svg"
        if not src.exists():
            print(f"  пропуск {name}: нет {src.name}")
            continue
        px = EMBLEM_PX if name == "emblem" else ICON_PX
        strip_background(src, OUT / "icons" / f"{name}.svg", px)

    print("Рамки и фон:")
    for name, width, crop, height in FRAMES:
        src = RAW / f"{name}.png"
        if not src.exists():
            print(f"  пропуск {name}: нет {src.name}")
            continue
        crop_and_shrink(src, OUT / f"{name}.png", width, crop, height)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

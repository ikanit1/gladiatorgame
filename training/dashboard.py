"""
Панель управления обучением гладиатора.

Запуск:  python training/dashboard.py

Что умеет:
  * запускает обучение или просмотр (сама поднимает и Python, и Godot
    в правильном порядке - Python первым, он держит сервер на порту 11008);
  * показывает прогресс: шаги, итерации, эпизоды, скорость, награду;
  * показывает боевую статистику, которую отдаёт сам агент:
    убийства, волны, удары мечом и ногой, промахи, урон, блоки, оглушения;
  * рисует кривую награды.

Данные берутся из runs/<эксперимент>/live_stats.json, который пишет
StatsWriter. Парсить консольный вывод SB3 было бы хрупко.

Зависимости: только tkinter из стандартной поставки Python.
"""

import json
import os
import pathlib
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNS = ROOT / "training" / "runs"

BG = "#15171c"
PANEL = "#1e2128"
FG = "#dfe3ea"
DIM = "#8b94a5"
ACCENT = "#d99a3c"
GOOD = "#6fbf5a"
BAD = "#d1584f"
FONT = ("Segoe UI", 10)
FONT_B = ("Segoe UI", 10, "bold")
FONT_BIG = ("Segoe UI", 20, "bold")


def find_godot() -> str:
    """Godot обычно не в PATH, поэтому ищем по типичным местам."""
    env = os.environ.get("GODOT_BIN")
    if env and pathlib.Path(env).exists():
        return env

    patterns = ["Godot*.exe", "godot*.exe"]
    places = [
        pathlib.Path.home() / "Desktop",
        pathlib.Path.home() / "Downloads",
        pathlib.Path("C:/Program Files/Godot"),
        ROOT,
    ]
    for place in places:
        if not place.exists():
            continue
        for pat in patterns:
            found = sorted(place.glob(pat))
            if found:
                return str(found[0])
    return "godot"


class Dashboard:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        root.title("AIfight — панель обучения")
        root.configure(bg=BG)
        root.geometry("1060x720")
        root.minsize(900, 620)

        self.proc_py: subprocess.Popen | None = None
        self.proc_godot: subprocess.Popen | None = None
        self.log_q: queue.Queue = queue.Queue()
        self.mode = "idle"
        self.stats_path: pathlib.Path | None = None
        self.curve: list = []

        self._build_ui()
        self._tick()

    # ------------------------------------------------------------------
    # Интерфейс
    # ------------------------------------------------------------------

    def _build_ui(self) -> None:
        top = tk.Frame(self.root, bg=PANEL, pady=10, padx=12)
        top.pack(fill="x")

        tk.Label(top, text="Эксперимент", bg=PANEL, fg=DIM, font=FONT).grid(row=0, column=0, sticky="w")
        self.exp_var = tk.StringVar(value="gladiator_v3")
        self.exp_box = ttk.Combobox(top, textvariable=self.exp_var, width=22,
                                    values=self._known_experiments(), font=FONT)
        self.exp_box.grid(row=1, column=0, padx=(0, 14))

        tk.Label(top, text="Шагов обучения", bg=PANEL, fg=DIM, font=FONT).grid(row=0, column=1, sticky="w")
        self.steps_var = tk.StringVar(value="700000")
        tk.Entry(top, textvariable=self.steps_var, width=10, font=FONT,
                 bg=BG, fg=FG, insertbackground=FG, relief="flat").grid(row=1, column=1, padx=(0, 14))

        tk.Label(top, text="Ускорение", bg=PANEL, fg=DIM, font=FONT).grid(row=0, column=2, sticky="w")
        self.speed_var = tk.StringVar(value="8")
        tk.Entry(top, textvariable=self.speed_var, width=6, font=FONT,
                 bg=BG, fg=FG, insertbackground=FG, relief="flat").grid(row=1, column=2, padx=(0, 14))

        self.btn_train = tk.Button(top, text="▶ Обучать", command=self.start_training,
                                   bg=ACCENT, fg="#1a1a1a", font=FONT_B, relief="flat",
                                   padx=16, pady=6, cursor="hand2")
        self.btn_train.grid(row=1, column=3, padx=4)

        self.btn_play = tk.Button(top, text="👁 Смотреть игру", command=self.start_play,
                                  bg="#4a7fb5", fg="#f2f5f8", font=FONT_B, relief="flat",
                                  padx=16, pady=6, cursor="hand2")
        self.btn_play.grid(row=1, column=4, padx=4)

        self.btn_stop = tk.Button(top, text="■ Стоп", command=self.stop_all,
                                  bg="#3a3f4a", fg=FG, font=FONT_B, relief="flat",
                                  padx=16, pady=6, cursor="hand2", state="disabled")
        self.btn_stop.grid(row=1, column=5, padx=4)

        tk.Label(top, text="Godot", bg=PANEL, fg=DIM, font=FONT).grid(row=0, column=6, sticky="w", padx=(14, 0))
        self.godot_var = tk.StringVar(value=find_godot())
        tk.Entry(top, textvariable=self.godot_var, width=34, font=("Segoe UI", 9),
                 bg=BG, fg=DIM, insertbackground=FG, relief="flat").grid(row=1, column=6, padx=(14, 0))

        self.status = tk.Label(self.root, text="готов к запуску", bg=BG, fg=DIM,
                               font=FONT, anchor="w", padx=14, pady=6)
        self.status.pack(fill="x")

        mid = tk.Frame(self.root, bg=BG)
        mid.pack(fill="both", expand=True, padx=12)

        self.prog_cells = self._make_group(mid, "ПРОГРЕСС", 0, [
            ("timesteps", "шагов"), ("iterations", "итераций"), ("episodes", "эпизодов"),
            ("fps", "шагов/сек"), ("elapsed", "время"), ("reward_mean", "награда"),
        ])
        self.combat_cells = self._make_group(mid, "БОЙ (в среднем за эпизод)", 1, [
            ("kills", "убито"), ("wave", "волна"), ("sword", "ударов мечом"),
            ("kicks", "пинков"), ("miss_pct", "промахов"), ("damage_dealt", "урона нанёс"),
            ("damage_taken", "урона принял"), ("blocks", "блоков"),
            ("staggers", "оглушений"), ("guard_breaks", "щит пробит"),
            ("potions", "зелий взял"), ("healed", "вылечено HP"),
        ])

        chart_box = tk.Frame(self.root, bg=PANEL)
        chart_box.pack(fill="both", expand=True, padx=12, pady=(10, 0))
        tk.Label(chart_box, text="НАГРАДА ЗА ЭПИЗОД", bg=PANEL, fg=DIM,
                 font=("Segoe UI", 9, "bold"), anchor="w", padx=10, pady=4).pack(fill="x")
        self.chart = tk.Canvas(chart_box, bg=PANEL, height=190, highlightthickness=0)
        self.chart.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        log_box = tk.Frame(self.root, bg=PANEL)
        log_box.pack(fill="both", expand=True, padx=12, pady=10)
        self.log = tk.Text(log_box, bg=PANEL, fg=DIM, font=("Consolas", 9),
                           height=7, relief="flat", wrap="none")
        self.log.pack(fill="both", expand=True, padx=8, pady=8)

    def _make_group(self, parent, title, col, fields):
        box = tk.Frame(parent, bg=PANEL)
        box.grid(row=0, column=col, sticky="nsew", padx=(0, 10) if col == 0 else 0)
        parent.grid_columnconfigure(col, weight=1 if col == 0 else 2)
        parent.grid_rowconfigure(0, weight=1)

        tk.Label(box, text=title, bg=PANEL, fg=DIM, font=("Segoe UI", 9, "bold"),
                 anchor="w", padx=10, pady=6).pack(fill="x")

        grid = tk.Frame(box, bg=PANEL)
        grid.pack(fill="both", expand=True, padx=10, pady=(0, 10))

        cells = {}
        per_row = 3
        for i, (key, label) in enumerate(fields):
            cell = tk.Frame(grid, bg=BG, padx=10, pady=8)
            cell.grid(row=i // per_row, column=i % per_row, sticky="nsew", padx=3, pady=3)
            grid.grid_columnconfigure(i % per_row, weight=1)
            v = tk.Label(cell, text="—", bg=BG, fg=FG, font=FONT_BIG, anchor="w")
            v.pack(fill="x")
            tk.Label(cell, text=label, bg=BG, fg=DIM, font=("Segoe UI", 9), anchor="w").pack(fill="x")
            cells[key] = v
        return cells

    def _known_experiments(self) -> list:
        if not RUNS.exists():
            return ["gladiator_v3"]
        found = sorted(d.name for d in RUNS.iterdir() if d.is_dir())
        return found or ["gladiator_v3"]

    # ------------------------------------------------------------------
    # Запуск процессов
    # ------------------------------------------------------------------

    def start_training(self) -> None:
        self._launch("training", [
            sys.executable, "-u", str(ROOT / "training" / "train_ppo.py"),
            "--connect",
            "--timesteps", self.steps_var.get(),
            "--speedup", self.speed_var.get(),
            "--experiment", self.exp_var.get(),
        ], scene="res://scenes/Training.tscn", headless=True)

    def start_play(self) -> None:
        self._launch("play", [
            sys.executable, "-u", str(ROOT / "training" / "play.py"),
            "--experiment", self.exp_var.get(),
        ], scene="res://scenes/Play.tscn", headless=False)

    def _launch(self, mode: str, cmd: list, scene: str, headless: bool) -> None:
        if self.proc_py is not None:
            self._log("уже запущено — сначала «Стоп»")
            return

        exp = self.exp_var.get()
        # У обучения и просмотра свои файлы, иначе просмотр затирает
        # накопленную статистику обучения
        self.stats_path = RUNS / exp / ("live_stats.json" if mode == "training"
                                        else "live_play.json")
        # Старый файл ввёл бы в заблуждение, пока новый прогон не начал писать
        if self.stats_path.exists():
            try:
                self.stats_path.unlink()
            except OSError:
                pass

        self.mode = mode
        self.curve = []
        self._set_running(True)
        self._log(f"$ {' '.join(cmd[1:])}")

        try:
            self.proc_py = subprocess.Popen(
                cmd, cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1)
        except OSError as e:
            self._log(f"не удалось запустить Python: {e}")
            self._set_running(False)
            return

        threading.Thread(target=self._pump, args=(self.proc_py,), daemon=True).start()
        threading.Thread(target=self._start_godot_when_ready,
                         args=(scene, headless), daemon=True).start()

    def _start_godot_when_ready(self, scene: str, headless: bool) -> None:
        """Godot должен подключаться к уже поднятому серверу, иначе handshake
        не состоится. Ждём соответствующей строки в выводе Python."""
        deadline = time.time() + 90
        while time.time() < deadline:
            if self.proc_py is None or self.proc_py.poll() is not None:
                return
            if self._server_ready:
                break
            time.sleep(0.3)
        else:
            self.log_q.put("сервер так и не поднялся — Godot не запущен")
            return

        cmd = [self.godot_var.get(), "--path", str(ROOT)]
        if headless:
            cmd.append("--headless")
        else:
            cmd += ["--resolution", "1600x900"]
        cmd += [scene, f"--speedup={self.speed_var.get()}"]

        self.log_q.put(f"$ godot {scene}")
        try:
            self.proc_godot = subprocess.Popen(
                cmd, cwd=str(ROOT), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            self.log_q.put(f"не удалось запустить Godot: {e}")

    _server_ready = False

    def _pump(self, proc: subprocess.Popen) -> None:
        for line in proc.stdout:
            line = line.rstrip()
            if not line:
                continue
            if "waiting for remote GODOT" in line:
                self._server_ready = True
            # Таблицы SB3 в лог не тащим - те же числа показаны виджетами
            if line.startswith("|") or line.startswith("---"):
                continue
            self.log_q.put(line)
        self.log_q.put("— процесс завершён —")

    def stop_all(self) -> None:
        for p in (self.proc_godot, self.proc_py):
            if p is not None and p.poll() is None:
                try:
                    p.terminate()
                except OSError:
                    pass
        self.proc_godot = None
        self.proc_py = None
        self._server_ready = False
        self._set_running(False)
        self._log("остановлено")

    def _set_running(self, running: bool) -> None:
        state = "disabled" if running else "normal"
        self.btn_train.configure(state=state)
        self.btn_play.configure(state=state)
        self.btn_stop.configure(state="normal" if running else "disabled")
        if not running:
            self.mode = "idle"

    # ------------------------------------------------------------------
    # Обновление
    # ------------------------------------------------------------------

    def _log(self, text: str) -> None:
        self.log.insert("end", text + "\n")
        self.log.see("end")
        if float(self.log.index("end")) > 400:
            self.log.delete("1.0", "200.0")

    def _tick(self) -> None:
        while True:
            try:
                self._log(self.log_q.get_nowait())
            except queue.Empty:
                break

        if self.proc_py is not None and self.proc_py.poll() is not None:
            self.stop_all()

        self._refresh_stats()
        self.root.after(400, self._tick)

    def _refresh_stats(self) -> None:
        if self.stats_path is None or not self.stats_path.exists():
            return
        try:
            data = json.loads(self.stats_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return  # файл переписывается прямо сейчас — прочитаем в следующий тик

        total = data.get("total_timesteps") or 0
        steps = data.get("timesteps") or 0
        if data.get("mode") == "play":
            self.prog_cells["timesteps"].configure(text="—")
        else:
            self.prog_cells["timesteps"].configure(
                text=f"{steps / 1000:.0f}k" + (f" / {total // 1000}k" if total else ""))

        self.prog_cells["iterations"].configure(text=str(data.get("iterations") or "—"))
        self.prog_cells["episodes"].configure(text=str(data.get("episodes") or 0))
        self.prog_cells["fps"].configure(text=str(data.get("fps") or "—"))

        el = data.get("elapsed_sec") or 0
        self.prog_cells["elapsed"].configure(
            text=f"{int(el) // 60}:{int(el) % 60:02d}" if el else "—")

        rm = data.get("reward_mean")
        cell = self.prog_cells["reward_mean"]
        cell.configure(text=f"{rm:.1f}" if rm is not None else "—",
                       fg=GOOD if (rm or 0) > 0 else BAD if rm is not None else FG)

        avg = data.get("combat_avg") or {}
        for key in ("kills", "wave", "sword", "kicks", "damage_dealt",
                    "damage_taken", "blocks", "staggers", "guard_breaks",
                    "potions", "healed"):
            v = avg.get(key)
            self.combat_cells[key].configure(
                text="—" if v is None else (f"{v:.0f}" if v >= 10 else f"{v:.1f}"))

        atk, miss = avg.get("attacks"), avg.get("misses")
        if atk:
            pct = 100.0 * (miss or 0) / atk
            self.combat_cells["miss_pct"].configure(
                text=f"{pct:.0f}%", fg=GOOD if pct < 25 else ACCENT if pct < 45 else BAD)

        status = {"training": "обучение идёт", "play": "идёт игра"}.get(data.get("mode"), "")
        if data.get("finished"):
            status += " — завершено"
        best = data.get("reward_best")
        if best is not None:
            status += f"   лучший эпизод: {best:.1f}"
        self.status.configure(text=status or "готов к запуску")

        self.curve = data.get("reward_curve") or []
        self._draw_chart()

    def _draw_chart(self) -> None:
        c = self.chart
        c.delete("all")
        w = c.winfo_width() or 800
        h = c.winfo_height() or 190
        pad = 26

        if len(self.curve) < 2:
            c.create_text(w // 2, h // 2, text="нет данных — запусти обучение или игру",
                          fill=DIM, font=FONT)
            return

        lo, hi = min(self.curve), max(self.curve)
        if hi - lo < 1e-6:
            hi = lo + 1.0

        c.create_line(pad, h - pad, w - 8, h - pad, fill="#2c313a")
        for frac, val in ((0.0, lo), (0.5, (lo + hi) / 2), (1.0, hi)):
            y = h - pad - frac * (h - 2 * pad)
            c.create_line(pad, y, w - 8, y, fill="#252a33")
            c.create_text(pad - 6, y, text=f"{val:.0f}", fill=DIM,
                          font=("Consolas", 8), anchor="e")

        # Нулевая линия важнее сетки: по ней сразу видно, вышел агент в плюс или нет
        if lo < 0 < hi:
            zy = h - pad - (0 - lo) / (hi - lo) * (h - 2 * pad)
            c.create_line(pad, zy, w - 8, zy, fill="#4a5160", dash=(3, 3))

        n = len(self.curve)
        def px(i): return pad + i / (n - 1) * (w - pad - 8)
        def py(v): return h - pad - (v - lo) / (hi - lo) * (h - 2 * pad)

        raw = []
        for i, v in enumerate(self.curve):
            raw += [px(i), py(v)]
        c.create_line(*raw, fill="#3e4756", width=1)

        # Скользящее среднее: сырая награда за эпизод слишком шумная,
        # тренд по ней на глаз не читается
        win = max(3, n // 25)
        smooth = []
        for i in range(n):
            a = max(0, i - win)
            chunk = self.curve[a:i + 1]
            smooth += [px(i), py(sum(chunk) / len(chunk))]
        if len(smooth) >= 4:
            c.create_line(*smooth, fill=ACCENT, width=2)

        c.create_text(w - 12, 12, text=f"эпизодов: {n}   последняя: {self.curve[-1]:.1f}",
                      fill=DIM, font=("Consolas", 9), anchor="ne")


def main() -> None:
    root = tk.Tk()
    app = Dashboard(root)
    root.protocol("WM_DELETE_WINDOW", lambda: (app.stop_all(), root.destroy()))
    root.mainloop()


if __name__ == "__main__":
    main()

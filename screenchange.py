#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ScreenChange — следит за выбранным монитором и сообщает об изменениях.

Плавающая кнопка «Запустить / Остановить» всегда висит поверх остальных окон
и перетаскивается мышью. Запуск снимает первый (эталонный) скриншот, дальше
каждые N секунд делается новый и сравнивается с ним. Остановка равнозначна
нажатию Escape: табличка убирается, слежение встаёт на паузу.

Linux / X11, GTK 3. Зависимости: python3-gi, gir1.2-gtk-3.0, python3-pil, python3-numpy.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys

MISSING = []
try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("GLibUnix", "2.0")
    from gi.repository import Gtk, Gdk, GLib, GLibUnix
except (ImportError, ValueError):
    MISSING.append("python3-gi gir1.2-gtk-3.0")
try:
    from PIL import ImageGrab
except ImportError:
    MISSING.append("python3-pil")
try:
    import numpy as np
except ImportError:
    MISSING.append("python3-numpy")

if MISSING:
    sys.stderr.write(
        "ScreenChange: не хватает зависимостей.\n"
        "  sudo apt install " + " ".join(MISSING) + "\n")
    sys.exit(1)

STATE_FILE = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "screenchange", "state.json")

# Допуск на канал: шум сглаживания не должен считаться изменением.
CHANNEL_TOLERANCE = 16

# Насколько надо увести мышь, чтобы нажатие стало перетаскиванием (пиксели).
DRAG_THRESHOLD = 6

ALERT_SOUND = "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"

CSS = b"""
#panel {
    background-color: rgba(24, 24, 27, 0.94);
    border: 1px solid rgba(255, 255, 255, 0.18);
    border-radius: 11px;
}
#status {
    color: rgba(255, 255, 255, 0.55);
    font-size: 9pt;
    padding-right: 2px;
}
#toggle { padding: 4px 14px; font-weight: bold; }
#quit {
    padding: 2px 8px;
    color: rgba(255, 255, 255, 0.55);
    background: none;
    border: none;
    box-shadow: none;
    text-shadow: none;
}
#quit:hover { color: #ffffff; }
#chooser {
    background-color: rgba(10, 10, 12, 0.62);
    border: 3px solid rgba(255, 255, 255, 0.22);
}
#chooser.hot {
    background-color: rgba(14, 40, 80, 0.72);
    border: 3px solid #4da3ff;
}
#chooser-title { color: #ffffff; font-size: 30pt; font-weight: bold; }
#chooser-name { color: rgba(255, 255, 255, 0.70); font-size: 14pt; }
#chooser-hint { color: #ffffff; font-size: 17pt; }
#chooser-exit { color: rgba(255, 255, 255, 0.55); font-size: 11pt; }
#alert { background-color: #c80000; }
#alert.inverted { background-color: #ffffff; }
#alert-text {
    color: #ffffff;
    font-size: 26pt;
    font-weight: bold;
}
#alert.inverted #alert-text { color: #c80000; }
"""


# --------------------------------------------------------------------------- #
# Вспомогательные функции
# --------------------------------------------------------------------------- #

def monitors():
    """Список мониторов: (имя, x, y, ширина, высота, масштаб)."""
    display = Gdk.Display.get_default()
    if display is None:
        sys.stderr.write("ScreenChange: нет доступа к дисплею (DISPLAY не задан?).\n")
        sys.exit(1)
    out = []
    for i in range(display.get_n_monitors()):
        mon = display.get_monitor(i)
        geo = mon.get_geometry()
        name = mon.get_model() or ("monitor-%d" % i)
        out.append((name, geo.x, geo.y, geo.width, geo.height, mon.get_scale_factor()))
    return out


def pick_monitor(wanted):
    """Монитор по имени/индексу; по умолчанию — нижний (с наибольшим Y)."""
    mons = monitors()
    if wanted is None:
        return max(mons, key=lambda m: m[2])
    if wanted.isdigit() and int(wanted) < len(mons):
        return mons[int(wanted)]
    for mon in mons:
        if mon[0] == wanted:
            return mon
    sys.stderr.write("ScreenChange: монитор %r не найден. Доступны: %s\n"
                     % (wanted, ", ".join(m[0] for m in mons)))
    sys.exit(1)


def sound_command():
    """Первый доступный проигрыватель для звука оповещения."""
    if os.path.exists(ALERT_SOUND):
        for player, args in (("pw-play", []), ("paplay", []),
                             ("ffplay", ["-nodisp", "-autoexit", "-loglevel", "quiet"])):
            if shutil.which(player):
                return [player] + args + [ALERT_SOUND]
    wav = "/usr/share/sounds/alsa/Front_Center.wav"
    if shutil.which("aplay") and os.path.exists(wav):
        return ["aplay", "-q", wav]
    return None


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(data):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
    except OSError:
        pass


# --------------------------------------------------------------------------- #
# Выбор экрана при старте
# --------------------------------------------------------------------------- #

class ChooserWindow(Gtk.Window):
    """Накрывает один монитор: щелчок по нему выбирает его для слежения."""

    def __init__(self, index, monitor, on_pick, on_cancel):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.index = index
        self.monitor = monitor
        self.seat = None
        self.on_pick = on_pick
        self.on_cancel = on_cancel

        name, mx, my, mw, mh, _scale = monitor

        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.SPLASHSCREEN)
        self.set_app_paintable(True)

        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)
        for text, css_name in (("Монитор %d" % (index + 1), "chooser-title"),
                               ("%s · %d×%d" % (name, mw, mh), "chooser-name"),
                               ("Нажмите, чтобы следить за этим экраном", "chooser-hint"),
                               ("Escape — выход", "chooser-exit")):
            label = Gtk.Label(label=text)
            label.set_name(css_name)
            box.pack_start(label, False, False, 0)

        body = Gtk.EventBox()
        body.set_name("chooser")
        body.add(box)
        body.add_events(Gdk.EventMask.BUTTON_PRESS_MASK
                        | Gdk.EventMask.ENTER_NOTIFY_MASK
                        | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        body.connect("button-press-event", lambda *_: self.on_pick(self.monitor))
        body.connect("enter-notify-event", self._hot, True)
        body.connect("leave-notify-event", self._hot, False)
        self.body = body
        self.add(body)

        self.connect("key-press-event", self._on_key)
        self.connect("delete-event", lambda *_: self.on_cancel() or True)

        # Окно ровно по границам своего монитора. Полноэкранный режим нужен,
        # чтобы накрыть и панель рабочего стола: иначе окно съедет под неё.
        self.move(mx, my)
        self.set_default_size(mw, mh)
        self.resize(mw, mh)
        screen = self.get_screen()
        display = Gdk.Display.get_default()
        if screen is not None and display is not None and index < display.get_n_monitors():
            self.fullscreen_on_monitor(screen, index)

    def grab_keyboard(self):
        """Escape должен срабатывать, даже если окну не отдали фокус."""
        gdk_window = self.get_window()
        if gdk_window is None:
            return
        display = gdk_window.get_display()
        seat = display.get_default_seat() if display else None
        if seat is None:
            return
        try:
            status = seat.grab(gdk_window, Gdk.SeatCapabilities.KEYBOARD,
                               True, None, None, None, None)
        except Exception:
            return
        if status == Gdk.GrabStatus.SUCCESS:
            self.seat = seat

    def release_keyboard(self):
        if self.seat is not None:
            try:
                self.seat.ungrab()
            except Exception:
                pass
            self.seat = None

    def _hot(self, _widget, _event, on):
        ctx = self.body.get_style_context()
        if on:
            ctx.add_class("hot")
        else:
            ctx.remove_class("hot")
        return False

    def _on_key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.on_cancel()
            return True
        return False


def choose_monitor():
    """Показать выбор на всех мониторах. Возвращает выбранный или None."""
    mons = monitors()
    if len(mons) == 1:
        return mons[0]

    picked = []
    windows = []

    def pick(monitor):
        picked.append(monitor)
        Gtk.main_quit()
        return True

    def cancel():
        Gtk.main_quit()
        return True

    for index, monitor in enumerate(mons):
        window = ChooserWindow(index, monitor, pick, cancel)
        windows.append(window)
        window.show_all()
    if windows:
        windows[0].present()
        windows[0].grab_keyboard()

    Gtk.main()

    for window in windows:
        window.release_keyboard()
        window.destroy()
    while Gtk.events_pending():
        Gtk.main_iteration()
    return picked[0] if picked else None


# --------------------------------------------------------------------------- #
# Табличка «Произошло обновление!»
# --------------------------------------------------------------------------- #

class AlertWindow(Gtk.Window):
    """Мигающая красная табличка по центру отслеживаемого экрана."""

    def __init__(self, monitor, on_dismiss):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.on_dismiss = on_dismiss
        self.monitor = monitor
        self.blink_id = None
        self.blink_on = True
        self.seat = None

        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.SPLASHSCREEN)
        self.set_resizable(False)
        self.set_default_size(700, 220)

        label = Gtk.Label(label="Произошло обновление!\nESC — закрыть и приостановить")
        label.set_name("alert-text")
        label.set_justify(Gtk.Justification.CENTER)
        label.set_line_wrap(True)

        self.body = Gtk.EventBox()
        self.body.set_name("alert")
        self.body.add(label)
        self.body.connect("button-press-event", lambda *_: self.dismiss())
        self.add(self.body)

        self.connect("key-press-event", self._on_key)
        self.connect("delete-event", lambda *_: self.dismiss() or True)

    # -- показ / скрытие -------------------------------------------------- #

    def pop_up(self):
        _, mx, my, mw, mh, _ = self.monitor
        width, height = 700, 220
        self.move(mx + (mw - width) // 2, my + (mh - height) // 2)
        self.show_all()
        self.set_keep_above(True)
        self.present()

        self._grab_keyboard()
        self._set_blink(True)
        if self.blink_id is None:
            self.blink_id = GLib.timeout_add(400, self._tick_blink)

    def dismiss(self):
        """Погасить табличку. Вызывается по Escape, клику и кнопке «Остановить»."""
        if self.blink_id is not None:
            GLib.source_remove(self.blink_id)
            self.blink_id = None
        self.release_keyboard()
        self.hide()
        if self.on_dismiss is not None:
            self.on_dismiss()

    # -- Escape поверх всего ---------------------------------------------- #

    def _grab_keyboard(self):
        """Перехват клавиатуры, чтобы Escape срабатывал без фокуса на окне."""
        gdk_window = self.get_window()
        if gdk_window is None:
            return
        display = gdk_window.get_display()
        seat = display.get_default_seat() if display else None
        if seat is None:
            return
        try:
            status = seat.grab(gdk_window, Gdk.SeatCapabilities.KEYBOARD,
                               True, None, None, None, None)
        except Exception:
            return
        if status == Gdk.GrabStatus.SUCCESS:
            self.seat = seat
        else:
            # Фокус перехватить не удалось — хотя бы поднимем окно наверх.
            if shutil.which("xdotool"):
                xid = gdk_window.get_xid() if hasattr(gdk_window, "get_xid") else None
                if xid:
                    subprocess.Popen(["xdotool", "windowactivate", str(xid)],
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)

    def release_keyboard(self):
        if self.seat is not None:
            try:
                self.seat.ungrab()
            except Exception:
                pass
            self.seat = None

    # -- мигание ---------------------------------------------------------- #

    def _tick_blink(self):
        self._set_blink(not self.blink_on)
        return True

    def _set_blink(self, on):
        self.blink_on = on
        ctx = self.body.get_style_context()
        if on:
            ctx.remove_class("inverted")
        else:
            ctx.add_class("inverted")

    def _on_key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.dismiss()
            return True
        return False


# --------------------------------------------------------------------------- #
# Плавающая кнопка + слежение
# --------------------------------------------------------------------------- #

class ControlPanel(Gtk.Window):
    """Маленькое окошко с кнопкой: всегда поверх всего, перетаскивается мышью."""

    def __init__(self, monitor, interval_sec, min_changed):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.monitor = monitor
        self.interval_ms = int(interval_sec * 1000)
        self.min_changed = min_changed
        self.baseline = None
        self.check_id = None
        self.keep_above_id = None
        self.save_id = None
        self.press_origin = None
        self.sound = sound_command()

        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.set_resizable(False)
        self.set_title("ScreenChange")

        # Прозрачный toplevel: скруглённые углы рисует внутренняя коробка.
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)
            self.set_app_paintable(True)
            self.connect("draw", self._on_draw)

        self._build_ui()
        self._restore_position()

        self.alert = AlertWindow(monitor, on_dismiss=self.stop)

        self.connect("key-press-event", self._on_key)
        self.connect("configure-event", self._on_configure)
        self.connect("destroy", lambda *_: self.quit())

    # -- интерфейс -------------------------------------------------------- #

    def _build_ui(self):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.set_border_width(8)

        grip = Gtk.DrawingArea()
        grip.set_size_request(10, 20)
        grip.connect("draw", self._draw_grip)
        grip.set_tooltip_text("Потяните, чтобы переместить окно")

        self.toggle = Gtk.Button(label="▶  Запустить")
        self.toggle.set_name("toggle")
        self.toggle.connect("clicked", lambda *_: self.toggle_watching())

        self.status = Gtk.Label(label="пауза")
        self.status.set_name("status")

        quit_btn = Gtk.Button(label="✕")
        quit_btn.set_name("quit")
        quit_btn.set_relief(Gtk.ReliefStyle.NONE)
        quit_btn.set_tooltip_text("Выйти из ScreenChange")
        quit_btn.connect("clicked", lambda *_: self.quit())

        row.pack_start(grip, False, False, 0)
        row.pack_start(self.toggle, False, False, 0)
        row.pack_start(self.status, False, False, 0)
        row.pack_end(quit_btn, False, False, 0)

        # Фон окна тянется мышью, кнопки при этом продолжают нажиматься.
        drag_area = Gtk.EventBox()
        drag_area.set_name("panel")
        drag_area.add(row)
        drag_area.add_events(Gdk.EventMask.BUTTON_PRESS_MASK
                             | Gdk.EventMask.BUTTON_RELEASE_MASK
                             | Gdk.EventMask.POINTER_MOTION_MASK)
        drag_area.connect("button-press-event", self._on_press)
        drag_area.connect("button-release-event", self._on_release)
        drag_area.connect("motion-notify-event", self._on_motion)
        drag_area.connect("realize", self._set_move_cursor)
        self.add(drag_area)

    @staticmethod
    def _on_draw(_widget, cr):
        cr.set_source_rgba(0, 0, 0, 0)
        cr.set_operator(1)  # cairo.OPERATOR_SOURCE
        cr.paint()
        cr.set_operator(2)  # cairo.OPERATOR_OVER
        return False

    def _restore_position(self):
        saved = load_state().get("position")
        if isinstance(saved, list) and len(saved) == 2:
            for _, mx, my, mw, mh, _s in monitors():
                if mx <= saved[0] < mx + mw and my <= saved[1] < my + mh:
                    self.move(int(saved[0]), int(saved[1]))
                    return
        # По умолчанию — на мониторе, за которым НЕ следим, чтобы не мешать.
        mons = monitors()
        others = [m for m in mons if m[0] != self.monitor[0]] or mons
        _, mx, my, mw, _mh, _s = others[0]
        self.move(mx + mw - 300, my + 24)

    @staticmethod
    def _draw_grip(widget, cr):
        """Шесть точек — подсказка, что окно можно тащить."""
        width = widget.get_allocated_width()
        height = widget.get_allocated_height()
        cr.set_source_rgba(1, 1, 1, 0.38)
        for row in range(3):
            for col in range(2):
                cr.arc(width / 2 + (col - 0.5) * 5,
                       height / 2 + (row - 1) * 5, 1.4, 0, 6.2832)
                cr.fill()
        return False

    @staticmethod
    def _set_move_cursor(widget):
        window = widget.get_window()
        if window is not None:
            window.set_cursor(Gdk.Cursor.new_from_name(widget.get_display(), "move"))

    def _on_press(self, _widget, event):
        # Не тащим сразу: иначе обычный щелчок уводил бы окно за курсором.
        if event.button == 1:
            self.press_origin = (event.x_root, event.y_root)
        return False

    def _on_release(self, *_):
        self.press_origin = None
        return False

    def _on_motion(self, _widget, event):
        if self.press_origin is None:
            return False
        dx = event.x_root - self.press_origin[0]
        dy = event.y_root - self.press_origin[1]
        if dx * dx + dy * dy < DRAG_THRESHOLD * DRAG_THRESHOLD:
            return False
        origin, self.press_origin = self.press_origin, None
        self.begin_move_drag(1, int(origin[0]), int(origin[1]), event.time)
        return True

    def _on_configure(self, *_):
        if self.save_id is not None:
            GLib.source_remove(self.save_id)
        self.save_id = GLib.timeout_add(600, self._save_position)
        return False

    def _save_position(self):
        self.save_id = None
        state = load_state()
        state["position"] = list(self.get_position())
        save_state(state)
        return False

    def _on_key(self, _widget, event):
        # Escape = «Остановить»: табличка гаснет, слежение на паузе.
        if event.keyval == Gdk.KEY_Escape:
            self.stop()
            return True
        return False

    # -- запуск / остановка ----------------------------------------------- #

    def toggle_watching(self):
        if self.check_id is None:
            self.start()
        else:
            self.stop()

    def start(self):
        """Снять первый (эталонный) скриншот и начать сравнение."""
        self.baseline = self.capture()
        if self.baseline is None:
            self.status.set_text("не вижу экран")
            return
        self.check_id = GLib.timeout_add(self.interval_ms, self._check)
        if self.keep_above_id is None:
            self.keep_above_id = GLib.timeout_add_seconds(10, self._reassert_above)
        self.toggle.set_label("⏸  Остановить")
        self.status.set_text("слежу")
        print("Слежу за %s %dx%d+%d+%d, интервал %d c, порог %d пикс."
              % (self.monitor[0], self.monitor[3], self.monitor[4],
                 self.monitor[1], self.monitor[2],
                 self.interval_ms // 1000, self.min_changed),
              flush=True)

    def stop(self):
        """Равнозначно нажатию Escape: убрать табличку и встать на паузу."""
        if self.alert.get_visible():
            self.alert.release_keyboard()
            self.alert.hide()
        if self.alert.blink_id is not None:
            GLib.source_remove(self.alert.blink_id)
            self.alert.blink_id = None
        if self.check_id is not None:
            GLib.source_remove(self.check_id)
            self.check_id = None
        self.baseline = None
        self.toggle.set_label("▶  Запустить")
        self.status.set_text("пауза")

    def quit(self):
        self.alert.release_keyboard()
        Gtk.main_quit()

    def _reassert_above(self):
        # Окно могло уйти под чужое полноэкранное — возвращаем наверх без кражи фокуса.
        self.set_keep_above(True)
        return True

    # -- сравнение -------------------------------------------------------- #

    def capture(self):
        """Скриншот отслеживаемого монитора."""
        _, mx, my, mw, mh, scale = self.monitor
        bbox = (mx * scale, my * scale, (mx + mw) * scale, (my + mh) * scale)
        try:
            image = ImageGrab.grab(bbox=bbox, xdisplay="")
        except Exception:
            return None  # например, экран заблокирован
        return np.asarray(image.convert("RGB"), dtype=np.int16)

    def _ignored_rects(self):
        """Прямоугольники собственных окон в координатах отслеживаемого экрана."""
        _, mx, my, mw, mh, scale = self.monitor
        rects = []
        for window in (self, self.alert):
            if not window.get_visible():
                continue
            wx, wy = window.get_position()
            ww, wh = window.get_size()
            x0 = max(0, (wx - mx) * scale)
            y0 = max(0, (wy - my) * scale)
            x1 = min(mw * scale, (wx + ww - mx) * scale)
            y1 = min(mh * scale, (wy + wh - my) * scale)
            if x1 > x0 and y1 > y0:
                rects.append((int(x0), int(y0), int(x1), int(y1)))
        return rects

    def _check(self):
        current = self.capture()
        if current is None or self.baseline is None:
            return True
        if current.shape != self.baseline.shape:
            self.baseline = current  # монитор переключили — берём новый эталон
            return True

        changed = (np.abs(current - self.baseline) > CHANNEL_TOLERANCE).any(axis=2)
        # Свои же окна не должны считаться изменением экрана.
        for x0, y0, x1, y1 in self._ignored_rects():
            changed[y0:y1, x0:x1] = False
        diff = int(changed.sum())

        self.baseline = current
        if diff >= self.min_changed:
            print("%s  изменение: %d пикс." % (
                GLib.DateTime.new_now_local().format("%H:%M:%S"), diff), flush=True)
            self._raise_alert()
            return False  # таймер перезапустится при следующем «Запустить»
        return True

    def _raise_alert(self):
        self.check_id = None
        self.baseline = None
        self.toggle.set_label("▶  Запустить")
        self.status.set_text("изменение!")
        self.alert.pop_up()
        self.set_keep_above(True)
        if self.sound:
            try:
                subprocess.Popen(self.sound, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            except OSError:
                pass


# --------------------------------------------------------------------------- #

def main():
    parser = argparse.ArgumentParser(
        description="Следит за монитором и предупреждает об изменениях на нём.")
    parser.add_argument("-i", "--interval-sec", type=float, default=5,
                        help="период проверки в секундах (по умолчанию 5)")
    parser.add_argument("-m", "--min-changed-pixels", type=int, default=30,
                        help="сколько пикселей должно измениться (по умолчанию 30)")
    parser.add_argument("-s", "--screen", metavar="ИМЯ|НОМЕР", default=None,
                        help="какой монитор отслеживать; задан — выбор при старте не показывается")
    parser.add_argument("-l", "--list-screens", action="store_true",
                        help="показать мониторы и выйти")
    args = parser.parse_args()

    if args.list_screens:
        for index, (name, x, y, width, height, scale) in enumerate(monitors()):
            print("%d: %s  %dx%d+%d+%d  масштаб %d"
                  % (index, name, width, height, x, y, scale))
        return

    Gtk.init([])
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # Ctrl+C в терминале не должен оставить перехват клавиатуры висеть.
    # Прерывание годится и для выбора экрана, и для основного цикла.
    def bail(*_):
        Gtk.main_quit()
        return True
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, bail)
    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, bail)

    # Какой экран сторожим: либо указан ключом, либо его выбирают щелчком.
    if args.screen is not None:
        monitor = pick_monitor(args.screen)
    else:
        monitor = choose_monitor()
        if monitor is None:
            print("Экран не выбран — выход.", flush=True)
            return
    print("Выбран экран %s %dx%d+%d+%d."
          % (monitor[0], monitor[3], monitor[4], monitor[1], monitor[2]), flush=True)

    panel = ControlPanel(monitor, args.interval_sec, args.min_changed_pixels)
    panel.show_all()
    panel.set_keep_above(True)

    print("ScreenChange готов. Нажмите «Запустить», чтобы снять первый скриншот.",
          flush=True)
    try:
        Gtk.main()
    finally:
        panel.alert.release_keyboard()


if __name__ == "__main__":
    main()

# ScreenChange

[Русский](#русский) | [English](#english)

---

## Русский

Утилита, которая следит за выбранным монитором и предупреждает, когда на нём что-то изменилось.

При запуске все мониторы накрываются полупрозрачными табличками — щёлкните по тому, за которым
надо следить. Если монитор один, этот шаг пропускается.

Дальше поверх всех окон висит маленькая плавающая панель с кнопкой **Запустить / Остановить** — её
можно перетаскивать мышью куда угодно. По нажатию «Запустить» делается первый (эталонный) скриншот;
дальше каждые N секунд снимается новый и сравнивается с ним. Если изменилось достаточно пикселей, по
центру отслеживаемого экрана появляется мигающая красная табличка «Произошло обновление!» со звуком.

### Как это работает

- **Выбор экрана** — один раз при старте программы, щелчком по нужному монитору. **Escape** — выход.
  Чтобы пропустить выбор, укажите монитор ключом (`--screen` / `-Screen`).
- **Запустить** — снимает первый скриншот, который и отслеживается дальше.
- **Остановить** — равнозначно нажатию **Escape**: табличка убирается, слежение встаёт на паузу.
  Пока табличка на экране, Escape перехватывается глобально, даже если окно не в фокусе.
- Следующее «Запустить» снимает новый эталонный скриншот — старый не используется.
- Панель по умолчанию появляется на мониторе, за которым **не** следим, и её положение запоминается
  между запусками.
- Собственные окна программы исключаются из сравнения, поэтому панель не вызывает ложных срабатываний,
  даже если перетащить её на отслеживаемый экран.
- Мелкие колебания цвета (шум сглаживания) изменением не считаются.

### Linux

Требуется X11 и Python 3. Всё остальное обычно уже стоит; если нет:

```sh
sudo apt install python3-gi gir1.2-gtk-3.0 python3-pil python3-numpy
```

Запуск:

```sh
./screenchange.sh
./screenchange.sh --interval-sec 10 --min-changed-pixels 100
./screenchange.sh --list-screens
```

| Параметр                      | По умолчанию | Описание                                                          |
|-------------------------------|--------------|-------------------------------------------------------------------|
| `-i`, `--interval-sec`        | `5`          | Период проверки в секундах                                        |
| `-m`, `--min-changed-pixels`  | `30`         | Сколько пикселей должно измениться, чтобы считать это обновлением  |
| `-s`, `--screen`              | спросить     | Какой монитор отслеживать (имя или номер из `--list-screens`); задан — выбор при старте не показывается |
| `-l`, `--list-screens`        | —            | Показать мониторы и выйти                                          |

Выход — кнопка **×** на панели или **Ctrl+C** в терминале.

Проверено на Ubuntu 26.04 (XFCE, X11). Под Wayland снимок экрана через X11 недоступен — нужен сеанс X11.

### Windows

Требуется Windows с PowerShell 5.1+ и .NET Framework — то и другое уже есть в системе.

Двойной клик по `ScreenChange.bat` или из консоли:

```bat
ScreenChange.bat
ScreenChange.bat -IntervalSec 10 -MinChangedPixels 100
ScreenChange.bat -ListScreens
```

| Параметр            | По умолчанию | Описание                                                          |
|---------------------|--------------|-------------------------------------------------------------------|
| `-IntervalSec`      | `5`          | Период проверки в секундах                                        |
| `-MinChangedPixels` | `30`         | Сколько пикселей должно измениться, чтобы считать это обновлением  |
| `-Screen`           | спросить     | Какой монитор отслеживать (имя или номер из `-ListScreens`); задан — выбор при старте не показывается |
| `-ListScreens`      | —            | Показать мониторы и выйти                                          |

Выход — кнопка **×** на панели или **Ctrl+C** в окне консоли.

---

## English

A utility that watches a chosen monitor and alerts you when something on it changes.

On startup every monitor is covered with a translucent card — click the one you want to watch. With a
single monitor this step is skipped.

After that a small floating panel with a **Start / Stop** button sits on top of every window and can
be dragged anywhere with the mouse. Pressing Start takes the first (baseline) screenshot; from then on
a new one is taken every N seconds and compared against it. If enough pixels have changed, a blinking
red "Update happened!" banner appears in the center of the watched screen, along with a sound.

### How it works

- **Picking the screen** happens once at startup, by clicking the monitor you want. **Escape** quits.
  Pass the monitor on the command line (`--screen` / `-Screen`) to skip the picker.
- **Start** takes the first screenshot — that is the one tracked from then on.
- **Stop** is equivalent to pressing **Escape**: the banner is dismissed and watching is paused.
  While the banner is up, Escape is grabbed globally, even if the window does not have focus.
- The next Start takes a fresh baseline screenshot; the old one is not reused.
- The panel defaults to the monitor that is **not** being watched, and its position is remembered
  between runs.
- The program's own windows are excluded from the comparison, so the panel never triggers a false
  alert — even if you drag it onto the watched screen.
- Small color fluctuations (anti-aliasing noise) are not counted as changes.

### Linux

Needs X11 and Python 3. The rest is usually already installed; if not:

```sh
sudo apt install python3-gi gir1.2-gtk-3.0 python3-pil python3-numpy
```

Run it with:

```sh
./screenchange.sh
./screenchange.sh --interval-sec 10 --min-changed-pixels 100
./screenchange.sh --list-screens
```

| Parameter                     | Default | Description                                           |
|-------------------------------|---------|-------------------------------------------------------|
| `-i`, `--interval-sec`        | `5`     | Check interval in seconds                             |
| `-m`, `--min-changed-pixels`  | `30`    | Changed pixels required to trigger an alert           |
| `-s`, `--screen`              | ask     | Monitor to watch (name or index from `--list-screens`); given, the picker is skipped |
| `-l`, `--list-screens`        | —       | List monitors and exit                                |

Quit with the **×** button on the panel, or **Ctrl+C** in the terminal.

Tested on Ubuntu 26.04 (XFCE, X11). Screen capture goes through X11, so an X11 session is required.

### Windows

Needs Windows with PowerShell 5.1+ and .NET Framework — both ship with the system.

Double-click `ScreenChange.bat`, or run from a console:

```bat
ScreenChange.bat
ScreenChange.bat -IntervalSec 10 -MinChangedPixels 100
ScreenChange.bat -ListScreens
```

| Parameter           | Default | Description                                          |
|---------------------|---------|------------------------------------------------------|
| `-IntervalSec`      | `5`     | Check interval in seconds                            |
| `-MinChangedPixels` | `30`    | Changed pixels required to trigger an alert          |
| `-Screen`           | ask     | Monitor to watch (name or index from `-ListScreens`); given, the picker is skipped |
| `-ListScreens`      | —       | List monitors and exit                               |

Quit with the **×** button on the panel, or **Ctrl+C** in the console window.

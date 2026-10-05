# ScreenChange

[Русский](#русский) | [English](#english)

---

## Русский

Небольшая утилита для Windows, которая следит за нижним монитором и предупреждает, когда на нём что-то изменилось.

Каждые N секунд делается скриншот экрана и сравнивается с предыдущим. Если изменилось достаточно пикселей, по центру этого экрана поверх всех окон появляется мигающая красная табличка «Произошло обновление!» со звуковым сигналом.

### Возможности

- Автоматически выбирает нижний монитор (с наибольшей координатой Y).
- Допуск на шум сглаживания: мелкие колебания цвета не считаются изменением.
- Табличка закрывается клавишей **ESC** (работает глобально, даже без фокуса) или кликом мышью.
- Пока табличка на экране, сравнение приостанавливается; после закрытия снимается новый эталонный скриншот.
- Не требует установки: только PowerShell и .NET Framework, которые уже есть в Windows.

### Запуск

Двойной клик по `ScreenChange.bat` или из консоли:

```bat
ScreenChange.bat
ScreenChange.bat -IntervalSec 10 -MinChangedPixels 100
```

| Параметр            | По умолчанию | Описание                                                    |
|---------------------|--------------|-------------------------------------------------------------|
| `-IntervalSec`      | `5`          | Период проверки в секундах                                  |
| `-MinChangedPixels` | `30`         | Сколько пикселей должно измениться, чтобы считать это обновлением |

Для выхода нажмите **Ctrl+C** в окне консоли.

### Требования

- Windows с PowerShell 5.1+
- .NET Framework (System.Windows.Forms, System.Drawing)

---

## English

A small Windows utility that watches your bottom monitor and alerts you when something on it changes.

Every N seconds it takes a screenshot of the screen and compares it with the previous one. If enough pixels have changed, a blinking red "Update happened!" banner pops up on top of all windows in the center of that screen, along with a sound.

### Features

- Automatically picks the bottom monitor (the one with the largest Y coordinate).
- Tolerates anti-aliasing noise: small color fluctuations are not counted as changes.
- Dismiss the banner with **ESC** (registered as a global hotkey, works without focus) or a mouse click.
- Comparison is paused while the banner is visible; a fresh baseline screenshot is taken after it is closed.
- Nothing to install: uses only PowerShell and .NET Framework that ship with Windows.

### Usage

Double-click `ScreenChange.bat`, or run from a console:

```bat
ScreenChange.bat
ScreenChange.bat -IntervalSec 10 -MinChangedPixels 100
```

| Parameter           | Default | Description                                         |
|---------------------|---------|-----------------------------------------------------|
| `-IntervalSec`      | `5`     | Check interval in seconds                           |
| `-MinChangedPixels` | `30`    | Number of changed pixels required to trigger an alert |

Press **Ctrl+C** in the console window to exit.

### Requirements

- Windows with PowerShell 5.1+
- .NET Framework (System.Windows.Forms, System.Drawing)

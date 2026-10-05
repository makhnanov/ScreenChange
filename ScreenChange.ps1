# Следит за нижним монитором: каждые 5 секунд делает скриншот и сравнивает с предыдущим.
# При изменении показывает красную табличку поверх всех окон по центру этого экрана. ESC — закрыть.
param(
    [int]$IntervalSec = 5,      # период проверки
    [int]$MinChangedPixels = 30 # сколько пикселей должно измениться, чтобы считать это обновлением
)

$code = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class ScreenWatcher : Form
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);

    const int WM_HOTKEY = 0x0312;
    const int HOTKEY_ID = 1;

    Screen target;
    Bitmap prev;
    Timer timer;
    int minChanged;
    bool alertShown;
    Label label;
    Timer blink;
    bool blinkOn;

    public static void Run(int intervalSec, int minChanged)
    {
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.Run(new ScreenWatcher(intervalSec, minChanged));
    }

    ScreenWatcher(int intervalSec, int minChanged)
    {
        this.minChanged = minChanged;
        // Нижний экран = тот, у которого наибольший Y
        target = Screen.AllScreens[0];
        foreach (var s in Screen.AllScreens) if (s.Bounds.Y > target.Bounds.Y) target = s;
        Console.WriteLine("Слежу за экраном " + target.DeviceName + " " + target.Bounds + ". Ctrl+C для выхода.");

        FormBorderStyle = FormBorderStyle.None;
        BackColor = Color.FromArgb(200, 0, 0);
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(700, 220);
        Location = new Point(target.Bounds.X + (target.Bounds.Width - Width) / 2,
                             target.Bounds.Y + (target.Bounds.Height - Height) / 2);
        KeyPreview = true;
        KeyDown += (s, e) => { if (e.KeyCode == Keys.Escape) HideAlert(); };

        label = new Label {
            Dock = DockStyle.Fill,
            ForeColor = Color.White,
            Font = new Font("Segoe UI", 26, FontStyle.Bold),
            TextAlign = ContentAlignment.MiddleCenter,
            Text = "Произошло обновление!\nНажмите ESC, чтобы закрыть"
        };
        label.Click += (s, e) => HideAlert();
        Controls.Add(label);

        // моргание: красный фон/белый текст <-> белый фон/красный текст
        blink = new Timer { Interval = 400 };
        blink.Tick += (s, e) => SetBlink(!blinkOn);

        Opacity = 0; // окно существует (для хоткея), но невидимо до срабатывания
        prev = Grab();
        timer = new Timer { Interval = intervalSec * 1000 };
        timer.Tick += (s, e) => Check();
        timer.Start();
    }

    protected override void SetVisibleCore(bool value)
    {
        // Не показывать окно при старте
        if (!IsHandleCreated) { CreateHandle(); value = false; }
        base.SetVisibleCore(value);
    }

    Bitmap Grab()
    {
        var b = target.Bounds;
        var bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
            g.CopyFromScreen(b.X, b.Y, 0, 0, b.Size);
        return bmp;
    }

    static int CountDiff(Bitmap a, Bitmap c)
    {
        var rect = new Rectangle(0, 0, a.Width, a.Height);
        var da = a.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var dc = c.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int n = da.Stride / 4 * a.Height;
            var pa = new int[n]; var pc = new int[n];
            Marshal.Copy(da.Scan0, pa, 0, n);
            Marshal.Copy(dc.Scan0, pc, 0, n);
            int diff = 0;
            for (int i = 0; i < n; i++) {
                int x = pa[i], y = pc[i];
                if (x == y) continue;
                // небольшой допуск, чтобы игнорировать шум сглаживания
                if (Math.Abs((x & 0xFF) - (y & 0xFF)) > 16 ||
                    Math.Abs(((x >> 8) & 0xFF) - ((y >> 8) & 0xFF)) > 16 ||
                    Math.Abs(((x >> 16) & 0xFF) - ((y >> 16) & 0xFF)) > 16)
                    diff++;
            }
            return diff;
        } finally { a.UnlockBits(da); c.UnlockBits(dc); }
    }

    void Check()
    {
        if (alertShown) return; // пока табличка на экране — не сравниваем
        Bitmap cur;
        try { cur = Grab(); } catch { return; } // напр. экран заблокирован
        int diff = CountDiff(prev, cur);
        prev.Dispose();
        prev = cur;
        if (diff >= minChanged) {
            Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  изменение: " + diff + " пикс.");
            ShowAlert();
        }
    }

    void ShowAlert()
    {
        alertShown = true;
        Opacity = 1;
        Show();
        TopMost = true;
        Activate();
        SetForegroundWindow(Handle);
        // ESC глобально, даже если Windows не отдала окну фокус
        RegisterHotKey(Handle, HOTKEY_ID, 0, (uint)Keys.Escape);
        System.Media.SystemSounds.Exclamation.Play();
        SetBlink(true);
        blink.Start();
    }

    void SetBlink(bool on)
    {
        blinkOn = on;
        BackColor = on ? Color.FromArgb(200, 0, 0) : Color.White;
        label.ForeColor = on ? Color.White : Color.FromArgb(200, 0, 0);
    }

    void HideAlert()
    {
        if (!alertShown) return;
        UnregisterHotKey(Handle, HOTKEY_ID);
        blink.Stop();
        Opacity = 0;
        Hide();
        alertShown = false;
        // новый эталон — без таблички
        var t = new Timer { Interval = 300 };
        t.Tick += (s, e) => { t.Stop(); t.Dispose(); prev.Dispose(); prev = Grab(); };
        t.Start();
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID) HideAlert();
        base.WndProc(ref m);
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms, System.Drawing
[ScreenWatcher]::Run($IntervalSec, $MinChangedPixels)

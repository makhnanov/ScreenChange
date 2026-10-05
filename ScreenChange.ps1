# ScreenChange — следит за выбранным монитором и сообщает об изменениях.
#
# Плавающая кнопка «Запустить / Остановить» всегда висит поверх остальных окон
# и перетаскивается мышью. Запуск снимает первый (эталонный) скриншот, дальше
# каждые N секунд делается новый и сравнивается с ним. Остановка равнозначна
# нажатию Escape: табличка убирается, слежение встаёт на паузу.
param(
    [int]$IntervalSec = 5,       # период проверки
    [int]$MinChangedPixels = 30, # сколько пикселей должно измениться, чтобы считать это обновлением
    [string]$Screen = $null,     # какой монитор отслеживать (имя или номер); по умолчанию нижний
    [switch]$ListScreens         # показать мониторы и выйти
)

$code = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class ScreenChange
{
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    // Допуск на канал: шум сглаживания не должен считаться изменением.
    public const int ChannelTolerance = 16;

    public static void ListScreens()
    {
        int i = 0;
        foreach (var s in Screen.AllScreens)
        {
            Console.WriteLine(i + ": " + s.DeviceName + "  " + s.Bounds.Width + "x" + s.Bounds.Height
                              + "+" + s.Bounds.X + "+" + s.Bounds.Y);
            i++;
        }
    }

    // Монитор по имени/номеру; по умолчанию — нижний (с наибольшим Y).
    public static Screen Pick(string wanted)
    {
        var all = Screen.AllScreens;
        if (String.IsNullOrEmpty(wanted))
        {
            var bottom = all[0];
            foreach (var s in all) if (s.Bounds.Y > bottom.Bounds.Y) bottom = s;
            return bottom;
        }
        int index;
        if (Int32.TryParse(wanted, out index) && index >= 0 && index < all.Length) return all[index];
        foreach (var s in all) if (s.DeviceName == wanted) return s;
        throw new ArgumentException("Монитор \"" + wanted + "\" не найден. Запустите с -ListScreens.");
    }

    public static void Run(int intervalSec, int minChanged, string wanted)
    {
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        // Какой экран сторожим: либо указан ключом, либо его выбирают щелчком.
        Screen target;
        if (!String.IsNullOrEmpty(wanted))
        {
            target = Pick(wanted);
        }
        else
        {
            target = ChooserForm.Choose();
            if (target == null)
            {
                Console.WriteLine("Экран не выбран — выход.");
                return;
            }
        }
        Console.WriteLine("Выбран экран " + target.DeviceName + " " + target.Bounds + ".");
        Application.Run(new ControlPanel(target, intervalSec, minChanged));
    }
}

// --------------------------------------------------------------------------- //
// Выбор экрана при старте
// --------------------------------------------------------------------------- //

public class ChooserForm : Form
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    const int WM_HOTKEY = 0x0312;
    const int HOTKEY_ID = 2;

    static readonly Color Idle = Color.FromArgb(10, 10, 12);
    static readonly Color Hot = Color.FromArgb(14, 40, 80);

    public Action<Screen> OnPick;
    public Action OnCancel;

    int number;
    Screen screen;
    bool hotkeyRegistered;

    // Показать накрывающие окна на всех мониторах и дождаться щелчка.
    public static Screen Choose()
    {
        var all = Screen.AllScreens;
        if (all.Length == 1) return all[0];

        Screen picked = null;
        var forms = new List<ChooserForm>();
        for (int i = 0; i < all.Length; i++)
        {
            var form = new ChooserForm(i + 1, all[i]);
            form.OnPick = delegate(Screen chosen) { picked = chosen; CloseAll(forms); };
            form.OnCancel = delegate { picked = null; CloseAll(forms); };
            forms.Add(form);
        }

        foreach (var form in forms) form.Show();
        forms[0].Activate();
        forms[0].GrabEscape();
        // Первое окно — главное: когда оно закроется, цикл сообщений закончится.
        Application.Run(forms[0]);
        foreach (var form in forms) form.Dispose();
        return picked;
    }

    static void CloseAll(List<ChooserForm> forms)
    {
        foreach (var form in forms.ToArray())
        {
            form.ReleaseEscape();
            form.Close();
        }
    }

    ChooserForm(int number, Screen screen)
    {
        this.number = number;
        this.screen = screen;

        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = screen.Bounds;
        BackColor = Idle;
        Opacity = 0.68;
        TopMost = true;
        ShowInTaskbar = false;
        KeyPreview = true;
        Cursor = Cursors.Hand;
        DoubleBuffered = true;

        Click += delegate { if (OnPick != null) OnPick(screen); };
        MouseEnter += delegate { BackColor = Hot; Invalidate(); };
        MouseLeave += delegate { BackColor = Idle; Invalidate(); };
        KeyDown += delegate(object s, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape && OnCancel != null) OnCancel();
        };
    }

    // Escape должен срабатывать, даже если окну не отдали фокус.
    public void GrabEscape()
    {
        hotkeyRegistered = RegisterHotKey(Handle, HOTKEY_ID, 0, (uint)Keys.Escape);
    }

    public void ReleaseEscape()
    {
        if (!hotkeyRegistered) return;
        UnregisterHotKey(Handle, HOTKEY_ID);
        hotkeyRegistered = false;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID && OnCancel != null) OnCancel();
        base.WndProc(ref m);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        // Подложка под подписью, чтобы текст читался на любом фоне.
        var block = new Rectangle(Width / 2 - 330, Height / 2 - 115, 660, 230);
        using (var path = Rounded(block, 18))
        using (var back = new SolidBrush(Color.FromArgb(150, 0, 0, 0)))
            g.FillPath(back, path);

        using (var center = new StringFormat())
        using (var big = new Font("Segoe UI", 30, FontStyle.Bold))
        using (var small = new Font("Segoe UI", 14))
        using (var mid = new Font("Segoe UI", 17))
        using (var tiny = new Font("Segoe UI", 11))
        using (var white = new SolidBrush(Color.White))
        using (var dim = new SolidBrush(Color.FromArgb(190, 190, 195)))
        {
            center.Alignment = StringAlignment.Center;
            float x = Width / 2f;
            float y = block.Y + 26;
            g.DrawString("Монитор " + number, big, white, x, y, center);
            y += 62;
            g.DrawString(screen.DeviceName + " · " + screen.Bounds.Width + "×" + screen.Bounds.Height,
                         small, dim, x, y, center);
            y += 38;
            g.DrawString("Нажмите, чтобы следить за этим экраном", mid, white, x, y, center);
            y += 42;
            g.DrawString("Escape — выход", tiny, dim, x, y, center);
        }
    }

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        path.AddArc(r.X, r.Y, radius * 2, radius * 2, 180, 90);
        path.AddArc(r.Right - radius * 2, r.Y, radius * 2, radius * 2, 270, 90);
        path.AddArc(r.Right - radius * 2, r.Bottom - radius * 2, radius * 2, radius * 2, 0, 90);
        path.AddArc(r.X, r.Bottom - radius * 2, radius * 2, radius * 2, 90, 90);
        path.CloseFigure();
        return path;
    }
}

// --------------------------------------------------------------------------- //
// Табличка «Произошло обновление!»
// --------------------------------------------------------------------------- //

public class AlertForm : Form
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);

    const int WM_HOTKEY = 0x0312;
    const int HOTKEY_ID = 1;

    static readonly Color Red = Color.FromArgb(200, 0, 0);

    public Action OnDismiss;

    Screen target;
    Label label;
    System.Windows.Forms.Timer blink;
    bool blinkOn;
    bool hotkeyRegistered;

    public AlertForm(Screen target)
    {
        this.target = target;

        FormBorderStyle = FormBorderStyle.None;
        BackColor = Red;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(700, 220);
        KeyPreview = true;

        label = new Label();
        label.Dock = DockStyle.Fill;
        label.ForeColor = Color.White;
        label.Font = new Font("Segoe UI", 26, FontStyle.Bold);
        label.TextAlign = ContentAlignment.MiddleCenter;
        label.Text = "Произошло обновление!\nESC — закрыть и приостановить";
        label.Click += delegate { Dismiss(); };
        Controls.Add(label);

        KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Dismiss(); };
        Click += delegate { Dismiss(); };

        blink = new System.Windows.Forms.Timer();
        blink.Interval = 400;
        blink.Tick += delegate { SetBlink(!blinkOn); };
    }

    public void PopUp()
    {
        var b = target.Bounds;
        Location = new Point(b.X + (b.Width - Width) / 2, b.Y + (b.Height - Height) / 2);
        Show();
        TopMost = true;
        Activate();
        SetForegroundWindow(Handle);
        // ESC глобально, даже если Windows не отдала окну фокус.
        hotkeyRegistered = RegisterHotKey(Handle, HOTKEY_ID, 0, (uint)Keys.Escape);
        System.Media.SystemSounds.Exclamation.Play();
        SetBlink(true);
        blink.Start();
    }

    // Только снимает табличку. Паузу ставит ControlPanel.Stop().
    public void Teardown()
    {
        blink.Stop();
        if (hotkeyRegistered)
        {
            UnregisterHotKey(Handle, HOTKEY_ID);
            hotkeyRegistered = false;
        }
        Hide();
    }

    void Dismiss()
    {
        if (OnDismiss != null) OnDismiss();
    }

    void SetBlink(bool on)
    {
        blinkOn = on;
        BackColor = on ? Red : Color.White;
        label.ForeColor = on ? Color.White : Red;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == HOTKEY_ID) Dismiss();
        base.WndProc(ref m);
    }
}

// --------------------------------------------------------------------------- //
// Плавающая кнопка + слежение
// --------------------------------------------------------------------------- //

public class ControlPanel : Form
{
    // Насколько надо увести мышь, чтобы нажатие стало перетаскиванием.
    const int DragThreshold = 6;

    static readonly Color PanelBack = Color.FromArgb(24, 24, 27);
    static readonly Color ButtonBack = Color.FromArgb(56, 56, 60);
    static readonly Color Dim = Color.FromArgb(150, 150, 155);

    Screen target;
    int intervalMs;
    int minChanged;

    int[] baseline;
    int baseW, baseH;
    System.Windows.Forms.Timer checkTimer;
    AlertForm alert;

    Button toggle;
    Label status;
    Control grip;

    bool pressed, dragging;
    Point pressOrigin, formOrigin;

    public ControlPanel(Screen target, int intervalSec, int minChanged)
    {
        this.target = target;
        this.intervalMs = intervalSec * 1000;
        this.minChanged = minChanged;

        FormBorderStyle = FormBorderStyle.None;
        BackColor = PanelBack;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(276, 50);
        KeyPreview = true;
        Text = "ScreenChange";

        BuildUi();
        RestorePosition();

        alert = new AlertForm(target);
        alert.OnDismiss = delegate { Stop(); };

        checkTimer = new System.Windows.Forms.Timer();
        checkTimer.Tick += delegate { Check(); };

        KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Stop(); };
        Load += delegate { ApplyRoundedCorners(); };
        FormClosed += delegate { alert.Teardown(); };

        Console.WriteLine("ScreenChange готов. Нажмите «Запустить», чтобы снять первый скриншот.");
    }

    // -- интерфейс -------------------------------------------------------- //

    void BuildUi()
    {
        grip = new Panel();
        grip.Bounds = new Rectangle(10, 15, 10, 20);
        grip.BackColor = PanelBack;
        grip.Cursor = Cursors.SizeAll;
        grip.Paint += DrawGrip;
        Controls.Add(grip);

        toggle = new Button();
        toggle.Bounds = new Rectangle(28, 10, 152, 30);
        toggle.Text = "▶  Запустить";
        toggle.FlatStyle = FlatStyle.Flat;
        toggle.FlatAppearance.BorderSize = 0;
        toggle.BackColor = ButtonBack;
        toggle.ForeColor = Color.White;
        toggle.Font = new Font("Segoe UI", 9.75f, FontStyle.Bold);
        toggle.Cursor = Cursors.Hand;
        toggle.Click += delegate { if (checkTimer.Enabled) Stop(); else Start(); };
        Controls.Add(toggle);

        status = new Label();
        status.Bounds = new Rectangle(188, 17, 56, 16);
        status.Text = "пауза";
        status.ForeColor = Dim;
        status.BackColor = PanelBack;
        status.Font = new Font("Segoe UI", 8.25f);
        Controls.Add(status);

        var quit = new Button();
        quit.Bounds = new Rectangle(246, 14, 22, 22);
        quit.Text = "×";
        quit.FlatStyle = FlatStyle.Flat;
        quit.FlatAppearance.BorderSize = 0;
        quit.BackColor = PanelBack;
        quit.ForeColor = Dim;
        quit.Font = new Font("Segoe UI", 9f);
        quit.Cursor = Cursors.Hand;
        quit.Click += delegate { Close(); };
        Controls.Add(quit);

        // Фон окна, ручка и подпись тянутся мышью; кнопки продолжают нажиматься.
        foreach (Control c in new Control[] { this, grip, status })
        {
            c.MouseDown += DragDown;
            c.MouseMove += DragMove;
            c.MouseUp += DragUp;
        }
        Cursor = Cursors.SizeAll;
    }

    // Шесть точек — подсказка, что окно можно тащить.
    void DrawGrip(object sender, PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (var brush = new SolidBrush(Color.FromArgb(97, 255, 255, 255)))
            for (int row = 0; row < 3; row++)
                for (int col = 0; col < 2; col++)
                    e.Graphics.FillEllipse(brush, 1 + col * 5, 3 + row * 5, 2.8f, 2.8f);
    }

    void ApplyRoundedCorners()
    {
        int r = 11;
        using (var path = new GraphicsPath())
        {
            path.AddArc(0, 0, r * 2, r * 2, 180, 90);
            path.AddArc(Width - r * 2, 0, r * 2, r * 2, 270, 90);
            path.AddArc(Width - r * 2, Height - r * 2, r * 2, r * 2, 0, 90);
            path.AddArc(0, Height - r * 2, r * 2, r * 2, 90, 90);
            path.CloseFigure();
            Region = new Region(path);
        }
    }

    // -- перетаскивание --------------------------------------------------- //

    void DragDown(object sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        pressed = true;
        dragging = false;
        pressOrigin = Control.MousePosition;
        formOrigin = Location;
        ((Control)sender).Capture = true;
    }

    void DragMove(object sender, MouseEventArgs e)
    {
        if (!pressed) return;
        Point now = Control.MousePosition;
        int dx = now.X - pressOrigin.X;
        int dy = now.Y - pressOrigin.Y;
        // Не тащим сразу: иначе обычный щелчок уводил бы окно за курсором.
        if (!dragging && dx * dx + dy * dy < DragThreshold * DragThreshold) return;
        dragging = true;
        Location = new Point(formOrigin.X + dx, formOrigin.Y + dy);
    }

    void DragUp(object sender, MouseEventArgs e)
    {
        ((Control)sender).Capture = false;
        if (pressed && dragging) SavePosition();
        pressed = false;
        dragging = false;
    }

    // -- положение окна между запусками ----------------------------------- //

    static string StateFile
    {
        get
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                                "ScreenChange", "position.txt");
        }
    }

    void RestorePosition()
    {
        try
        {
            if (File.Exists(StateFile))
            {
                var parts = File.ReadAllText(StateFile).Split(',');
                int x = Int32.Parse(parts[0].Trim());
                int y = Int32.Parse(parts[1].Trim());
                foreach (var s in Screen.AllScreens)
                    if (s.Bounds.Contains(x, y)) { Location = new Point(x, y); return; }
            }
        }
        catch { }

        // По умолчанию — на мониторе, за которым НЕ следим, чтобы не мешать.
        Screen host = target;
        foreach (var s in Screen.AllScreens)
            if (s.DeviceName != target.DeviceName) { host = s; break; }
        Location = new Point(host.Bounds.Right - Width - 24, host.Bounds.Y + 24);
    }

    void SavePosition()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StateFile));
            File.WriteAllText(StateFile, Location.X + "," + Location.Y);
        }
        catch { }
    }

    // -- запуск / остановка ----------------------------------------------- //

    // Снять первый (эталонный) скриншот и начать сравнение.
    void Start()
    {
        if (!Grab(out baseline, out baseW, out baseH))
        {
            status.Text = "не вижу экран";
            return;
        }
        checkTimer.Interval = intervalMs;
        checkTimer.Start();
        toggle.Text = "■  Остановить";
        status.Text = "слежу";
        Console.WriteLine("Слежу за " + target.DeviceName + " " + target.Bounds
                          + ", интервал " + (intervalMs / 1000) + " c, порог " + minChanged + " пикс.");
    }

    // Равнозначно нажатию Escape: убрать табличку и встать на паузу.
    void Stop()
    {
        alert.Teardown();
        checkTimer.Stop();
        baseline = null;
        toggle.Text = "▶  Запустить";
        status.Text = "пауза";
    }

    // -- сравнение -------------------------------------------------------- //

    bool Grab(out int[] pixels, out int w, out int h)
    {
        pixels = null;
        var b = target.Bounds;
        w = b.Width;
        h = b.Height;
        try
        {
            using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                    g.CopyFromScreen(b.X, b.Y, 0, 0, b.Size);
                var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly,
                                        PixelFormat.Format32bppArgb);
                try
                {
                    var px = new int[w * h];
                    for (int y = 0; y < h; y++)
                        Marshal.Copy(new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride),
                                     px, y * w, w);
                    pixels = px;
                }
                finally { bmp.UnlockBits(data); }
            }
            return true;
        }
        catch { return false; } // например, экран заблокирован
    }

    // Прямоугольники собственных окон в координатах отслеживаемого экрана.
    List<Rectangle> IgnoredRects()
    {
        var list = new List<Rectangle>();
        var b = target.Bounds;
        foreach (Form f in new Form[] { this, alert })
        {
            if (f == null || !f.Visible) continue;
            var r = Rectangle.Intersect(f.Bounds, b);
            if (r.Width > 0 && r.Height > 0)
                list.Add(new Rectangle(r.X - b.X, r.Y - b.Y, r.Width, r.Height));
        }
        return list;
    }

    static int CountDiff(int[] a, int[] c, int w, int h, List<Rectangle> ignore)
    {
        int diff = 0;
        for (int y = 0; y < h; y++)
        {
            int row = y * w;
            for (int x = 0; x < w; x++)
            {
                int p = a[row + x], q = c[row + x];
                if (p == q) continue;
                if (Math.Abs((p & 0xFF) - (q & 0xFF)) <= ScreenChange.ChannelTolerance &&
                    Math.Abs(((p >> 8) & 0xFF) - ((q >> 8) & 0xFF)) <= ScreenChange.ChannelTolerance &&
                    Math.Abs(((p >> 16) & 0xFF) - ((q >> 16) & 0xFF)) <= ScreenChange.ChannelTolerance)
                    continue;
                // Свои же окна не должны считаться изменением экрана.
                bool masked = false;
                for (int k = 0; k < ignore.Count; k++)
                    if (ignore[k].Contains(x, y)) { masked = true; break; }
                if (!masked) diff++;
            }
        }
        return diff;
    }

    void Check()
    {
        int[] cur;
        int w, h;
        if (!Grab(out cur, out w, out h)) return;
        if (baseline == null) return;
        if (w != baseW || h != baseH)
        {
            baseline = cur; baseW = w; baseH = h; // монитор переключили — новый эталон
            return;
        }

        int diff = CountDiff(baseline, cur, w, h, IgnoredRects());
        baseline = cur;
        if (diff >= minChanged)
        {
            Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  изменение: " + diff + " пикс.");
            RaiseAlert();
        }
    }

    void RaiseAlert()
    {
        checkTimer.Stop();
        baseline = null;
        toggle.Text = "▶  Запустить";
        status.Text = "изменение!";
        alert.PopUp();
        TopMost = true;
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms, System.Drawing

if ($ListScreens) {
    [ScreenChange]::ListScreens()
    return
}

[ScreenChange]::Run($IntervalSec, $MinChangedPixels, $Screen)

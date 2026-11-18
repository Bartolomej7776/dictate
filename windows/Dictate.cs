// Push-to-talk dictation for Windows. Compiles with the .NET Framework csc (C# 5), no installs needed.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class Dictate : ApplicationContext
{
    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    const int LLKHF_INJECTED = 0x10;

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int mciSendString(string cmd, StringBuilder ret, int len, IntPtr cb);

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize, dwTime; }

    static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "dictate");
    static readonly string WavPath = Path.Combine(Path.GetTempPath(), "dictate.wav");

    readonly HookProc hookProc;
    IntPtr hook;
    int lastHookTick = Environment.TickCount, lastRehook;
    bool keySinceRehook = true;
    readonly NotifyIcon tray;
    readonly Control ui = new Control();
    readonly string server;
    readonly Dictionary<int, Dictionary<string, object>> hotkeys = new Dictionary<int, Dictionary<string, object>>();
    readonly double minHold, tail;
    readonly bool beep, restoreClipboard;
    readonly string hermesUrl, hermesSecret, hermesSource;

    int held = -1;
    DateTime pressedAt;
    bool recording;
    int busy;
    int gen;
    int winPassthrough = -1;
    // Some wireless keyboards (seen on a Razer HyperSpeed dongle) sometimes withhold a key-up until the next key press. Windows'
    // auto-repeat stops at the real release, so a stalled repeat stream is treated as the release.
    DateTime lastRepeat;
    bool repeating;
    int lateUp = -1;
    bool copilot, shiftSwallowed;
    HashSet<int> copilotUps = new HashSet<int>();
    System.Windows.Forms.Timer repeatWatch;

    void WatchRepeats()
    {
        if (held < 0 || !repeating || (DateTime.Now - lastRepeat).TotalMilliseconds < 150) return;
        Log("auto-repeat stopped; treating as release");
        lateUp = held;
        Release();
    }

    static bool IsWin(int vk)
    {
        return vk == (int)Keys.LWin || vk == (int)Keys.RWin;
    }

    static void Log(string msg)
    {
        try { File.AppendAllText(Path.Combine(Dir, "dictate.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff ") + msg + "\r\n"); }
        catch (IOException) { }
    }

    Dictate()
    {
        Directory.CreateDirectory(Dir);
        var cfgPath = Path.Combine(Dir, "config.json");
        var cfg = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(File.ReadAllText(cfgPath));
        server = ((string)cfg["server"]).TrimEnd('/');
        foreach (var kv in (Dictionary<string, object>)cfg["keys"])
            hotkeys[(int)(Keys)Enum.Parse(typeof(Keys), kv.Key)] = (Dictionary<string, object>)kv.Value;
        minHold = Num(cfg, "min_hold", 0.3);
        tail = Num(cfg, "tail", 0.4);
        beep = !cfg.ContainsKey("beep") || (bool)cfg["beep"];
        restoreClipboard = !cfg.ContainsKey("restore_clipboard") || (bool)cfg["restore_clipboard"];
        if (cfg.ContainsKey("hermes"))
        {
            var hc = (Dictionary<string, object>)cfg["hermes"];
            hermesUrl = (string)hc["url"];
            hermesSecret = (string)hc["secret"];
            hermesSource = hc.ContainsKey("source") ? (string)hc["source"] : Environment.MachineName;
        }

        ui.CreateControl();
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open log", null, delegate { Process.Start(Path.Combine(Dir, "dictate.log")); });
        menu.Items.Add("Edit config (restart after)", null, delegate { Process.Start("notepad.exe", cfgPath); });
        menu.Items.Add("Exit", null, delegate { tray.Visible = false; Application.Exit(); });
        tray = new NotifyIcon { Icon = System.Drawing.SystemIcons.Information, Text = "Dictate (hold " + string.Join("/", KeyNames()) + ")", ContextMenuStrip = menu, Visible = true };

        repeatWatch = new System.Windows.Forms.Timer { Interval = 40 };
        repeatWatch.Tick += delegate { WatchRepeats(); };
        repeatWatch.Start();

        hookProc = OnKey;
        hook = SetWindowsHookEx(WH_KEYBOARD_LL, hookProc, GetModuleHandle(null), 0);
        // Windows silently removes a low-level hook whose callback once runs past LowLevelHooksTimeout
        // (sleep/resume, heavy load). Input the hook never saw means it is gone: install it again.
        var hookWatch = new System.Windows.Forms.Timer { Interval = 5000 };
        hookWatch.Tick += delegate { WatchHook(); };
        hookWatch.Start();
        Log("ready; server " + server + "; keys " + string.Join(",", KeyNames()));
    }

    void WatchHook()
    {
        var li = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
        if (held >= 0 || busy != 0 || !GetLastInputInfo(ref li)) return;
        int now = Environment.TickCount;
        if ((int)li.dwTime - lastHookTick < 3000 || now - lastRehook < 60000) return;
        lastRehook = now;
        UnhookWindowsHookEx(hook);
        hook = SetWindowsHookEx(WH_KEYBOARD_LL, hookProc, GetModuleHandle(null), 0);
        lastHookTick = now;
        // Mouse-only stretches (gaming) also look like unseen input; log once per stretch.
        if (keySinceRehook) Log("input the hook did not see; keyboard hook reinstalled (repeats unlogged until a key arrives)");
        keySinceRehook = false;
    }

    static double Num(Dictionary<string, object> d, string k, double def)
    {
        return d.ContainsKey(k) ? Convert.ToDouble(d[k]) : def;
    }

    IEnumerable<string> KeyNames()
    {
        foreach (var k in hotkeys.Keys) yield return ((Keys)k).ToString();
    }

    IntPtr OnKey(int nCode, IntPtr wParam, IntPtr lParam)
    {
        lastHookTick = Environment.TickCount;
        keySinceRehook = true;
        if (nCode >= 0)
        {
            var k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            int msg = wParam.ToInt32();
            bool down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN, up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            int vk = (int)k.vkCode;
            if ((held >= 0 || winPassthrough >= 0) && !(down && (vk == held || (copilot && (vk == 0x5B || vk == 0xA0)))))
                Log(string.Format("  key {0} {1} vk=0x{2:X2} scan=0x{3:X2} flags=0x{4:X2} held={5} pass={6} busy={7}",
                    (Keys)vk, down ? "down" : up ? "up" : "msg" + msg, vk, k.scanCode, k.flags, held, winPassthrough, busy));
            if ((k.flags & LLKHF_INJECTED) == 0)
            {
                // A Win hotkey is hidden from Windows while held (otherwise releasing it opens Start/Search,
                // and Windows 11 ignores the usual mask-key trick). It is replayed when it turns out to be
                // a shortcut (Win+E) or a quick tap.
                if (winPassthrough >= 0)
                {
                    if (up && vk == winPassthrough) winPassthrough = -1;
                    return CallNextHookEx(hook, nCode, wParam, lParam);
                }
                if (vk == lateUp && held < 0 && !copilot)
                {
                    lateUp = -1;
                    if (up) return IsWin(vk) ? (IntPtr)1 : CallNextHookEx(hook, nCode, wParam, lParam);
                }
                // The Copilot key arrives as LWin, (LShift), F23, and the keyboard repeats all three while
                // held. LWin starts a dictation hold; an F23 right after it turns the hold into the F23 action.
                bool copilotPart = vk == 0x5B || vk == 0xA0 || vk == 0x86;
                if (copilot)
                {
                    if (copilotPart && down && held >= 0) { lastRepeat = DateTime.Now; repeating = true; return (IntPtr)1; }
                    if (copilotPart && up)
                    {
                        if (held >= 0) Release();
                        copilotUps.Remove(vk);
                        if (copilotUps.Count == 0) copilot = false;
                        return (IntPtr)1;
                    }
                    copilot = false;
                    if (held >= 0 && down) { Cancel(); return CallNextHookEx(hook, nCode, wParam, lParam); }
                }
                bool early = held == 0x5B && (DateTime.Now - pressedAt).TotalMilliseconds < 400;
                if (early && down && vk == 0xA0) { shiftSwallowed = true; return (IntPtr)1; }
                if (early && down && vk == 0x86 && hotkeys.ContainsKey(0x86))
                {
                    Log("copilot key");
                    held = 0x86;
                    copilot = true;
                    repeating = false;
                    copilotUps = new HashSet<int> { 0x5B, 0xA0, 0x86 };
                    return (IntPtr)1;
                }
                if (held < 0 && down && hotkeys.ContainsKey(vk) && busy == 0)
                {
                    Start(vk);
                    if (IsWin(vk)) return (IntPtr)1;
                }
                else if (held >= 0 && down && vk == held)
                {
                    lastRepeat = DateTime.Now;
                    repeating = true;
                    if (IsWin(vk)) return (IntPtr)1;
                }
                else if (held >= 0 && down)
                {
                    int h = held;
                    Cancel();
                    if (IsWin(h))
                    {
                        keybd_event((byte)h, 0x5B, 1, UIntPtr.Zero);
                        if (shiftSwallowed) keybd_event(0xA0, 0x2A, 0, UIntPtr.Zero);
                        keybd_event((byte)vk, (byte)k.scanCode, k.flags & 1, UIntPtr.Zero);
                        winPassthrough = h;
                        return (IntPtr)1;
                    }
                }
                else if (held >= 0 && up && vk == held)
                {
                    bool tap = (DateTime.Now - pressedAt).TotalSeconds < minHold;
                    Release();
                    if (IsWin(vk))
                    {
                        if (tap)
                        {
                            keybd_event((byte)vk, 0x5B, 1, UIntPtr.Zero);
                            keybd_event((byte)vk, 0x5B, 1 | 2, UIntPtr.Zero);
                        }
                        return (IntPtr)1;
                    }
                }
                // F13-F24 hotkeys are swallowed: the Copilot key sends Win+Shift+F23, and letting F23
                // through would launch Copilot on every dictation.
                if (hotkeys.ContainsKey(vk) && vk >= 0x7C && vk <= 0x87) return (IntPtr)1;
            }
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    static void Mci(string cmd)
    {
        int rc = mciSendString(cmd, null, 0, IntPtr.Zero);
        if (rc != 0) throw new Exception("mci '" + cmd + "' failed: " + rc);
    }

    // The keyboard hook must return fast (Windows drops slow hooks), so all MCI work is posted to the
    // message queue; posting also keeps start/cancel/release in order.
    void Post(MethodInvoker fn)
    {
        ui.BeginInvoke(fn);
    }

    void Start(int vk)
    {
        held = vk;
        pressedAt = DateTime.Now;
        repeating = false;
        shiftSwallowed = false;
        int myGen = ++gen;
        Log("press " + (Keys)vk);
        Post(delegate
        {
            try
            {
                mciSendString("close dictrec", null, 0, IntPtr.Zero);
                Mci("open new type waveaudio alias dictrec");
                Mci("set dictrec time format ms bitspersample 16 channels 1 samplespersec 16000 bytespersec 32000 alignment 2");
                Mci("record dictrec");
                recording = true;
                Log("recording");
            }
            catch (Exception ex) { Log(ex.Message); held = -1; Beep(220, 150); return; }
            // Beep only once the hold is long enough to count, so Win+E style shortcuts stay silent.
            var t = new System.Windows.Forms.Timer { Interval = (int)(minHold * 1000) };
            t.Tick += delegate
            {
                t.Dispose();
                if (gen != myGen || held < 0 || !recording) return;
                Beep(880, 70);
            };
            t.Start();
        });
    }

    void Cancel()
    {
        Log("cancel");
        held = -1;
        Post(delegate
        {
            if (recording) { recording = false; mciSendString("close dictrec", null, 0, IntPtr.Zero); }
        });
    }

    void Release()
    {
        var opts = hotkeys[held];
        held = -1;
        double heldFor = (DateTime.Now - pressedAt).TotalSeconds;
        Log(string.Format("release after {0:F2}s", heldFor));
        if (heldFor < minHold) { Cancel(); return; }
        Interlocked.Exchange(ref busy, 1);
        Post(delegate
        {
            if (!recording) { busy = 0; return; }
            var t = new System.Windows.Forms.Timer { Interval = (int)(tail * 1000) };
            t.Tick += delegate
            {
                t.Dispose();
                recording = false;
                try
                {
                    Mci("stop dictrec");
                    Mci("save dictrec \"" + WavPath + "\"");
                }
                catch (Exception ex) { Log(ex.Message); Beep(220, 150); busy = 0; return; }
                finally { mciSendString("close dictrec", null, 0, IntPtr.Zero); }
                Log("saved");
                Beep(660, 70);
                var wav = File.ReadAllBytes(WavPath);
                ThreadPool.QueueUserWorkItem(delegate { Finish(wav, opts); });
            };
            t.Start();
        });
    }

    void Finish(byte[] wav, Dictionary<string, object> opts)
    {
        try
        {
            var sw = Stopwatch.StartNew();
            var text = Transcribe(wav, opts).Trim();
            Log(string.Format("{0:F1}s audio -> {1:F2}s: {2}", (wav.Length - 44) / 32000.0, sw.Elapsed.TotalSeconds, text));
            if (text.Length == 0) return;
            if (opts.ContainsKey("action") && (string)opts["action"] == "hermes")
            {
                SendToHermes(text);
                Beep(990, 60);
                Beep(1320, 80);
            }
            else ui.Invoke((MethodInvoker)delegate { Paste(text + " "); });
        }
        catch (Exception ex) { Log("transcribe failed: " + ex.Message); Beep(220, 150); }
        finally { busy = 0; }
    }

    string Transcribe(byte[] wav, Dictionary<string, object> opts)
    {
        var boundary = Guid.NewGuid().ToString("N");
        var fields = new Dictionary<string, string> { { "model", "whisper-1" }, { "response_format", "json" } };
        foreach (var k in new[] { "model", "language", "prompt" })
            if (opts.ContainsKey(k) && opts[k] != null) fields[k] = (string)opts[k];
        var body = new MemoryStream();
        Action<string> w = s => { var b = Encoding.UTF8.GetBytes(s); body.Write(b, 0, b.Length); };
        foreach (var f in fields)
            w("--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + f.Key + "\"\r\n\r\n" + f.Value + "\r\n");
        w("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n");
        body.Write(wav, 0, wav.Length);
        w("\r\n--" + boundary + "--\r\n");

        var req = (HttpWebRequest)WebRequest.Create(server + "/v1/audio/transcriptions");
        req.Method = "POST";
        req.Timeout = 60000;
        req.ContentType = "multipart/form-data; boundary=" + boundary;
        var bytes = body.ToArray();
        req.ContentLength = bytes.Length;
        using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
        using (var resp = req.GetResponse())
        using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
        {
            var json = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(r.ReadToEnd());
            return (string)json["text"];
        }
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    static string ForegroundInfo()
    {
        var h = GetForegroundWindow();
        var sb = new StringBuilder(256);
        GetWindowText(h, sb, 256);
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        string name = "?";
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch (ArgumentException) { }
        return name + " \"" + sb + "\"";
    }

    // Hermes Agent's webhook route runs the request and delivers the reply wherever the route says.
    // Generic HMAC V2: hex HMAC-SHA256 of "<unix timestamp>.<body>".
    void SendToHermes(string text)
    {
        var body = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(
            new Dictionary<string, string> { { "text", text }, { "source", hermesSource } }));
        var ts = ((long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds).ToString();
        string sig;
        using (var h = new System.Security.Cryptography.HMACSHA256(Encoding.UTF8.GetBytes(hermesSecret)))
        {
            var mac = h.ComputeHash(Encoding.UTF8.GetBytes(ts + ".").Concat(body).ToArray());
            sig = BitConverter.ToString(mac).Replace("-", "").ToLowerInvariant();
        }
        var req = (HttpWebRequest)WebRequest.Create(hermesUrl);
        req.Method = "POST";
        req.Timeout = 15000;
        req.ContentType = "application/json";
        req.Headers["X-Webhook-Timestamp"] = ts;
        req.Headers["X-Webhook-Signature-V2"] = sig;
        req.ContentLength = body.Length;
        using (var s = req.GetRequestStream()) s.Write(body, 0, body.Length);
        using (var resp = (HttpWebResponse)req.GetResponse())
            Log("sent to Hermes: HTTP " + (int)resp.StatusCode);
    }

    void Paste(string text)
    {
        Log("pasting into " + ForegroundInfo());
        string old = null;
        if (restoreClipboard && Clipboard.ContainsText()) old = Clipboard.GetText();
        Clipboard.SetText(text);
        // Injected keys pass through this thread's own keyboard hook, so inject from another thread
        // and let the hook thread keep pumping.
        ThreadPool.QueueUserWorkItem(delegate
        {
            Thread.Sleep(30);
            Log(string.Format("key state before paste: LWin={0} RWin={1} Ctrl={2} Shift={3} Alt={4}",
                Down(0x5B), Down(0x5C), Down(0x11), Down(0x10), Down(0x12)));
            keybd_event(0x11, 0x1D, 0, UIntPtr.Zero);
            keybd_event(0x56, 0x2F, 0, UIntPtr.Zero);
            keybd_event(0x56, 0x2F, 2, UIntPtr.Zero);
            keybd_event(0x11, 0x1D, 2, UIntPtr.Zero);
            Log("ctrl+v sent");
            if (old != null)
            {
                Thread.Sleep(600);
                ui.BeginInvoke((MethodInvoker)delegate { try { Clipboard.SetText(old); } catch (ExternalException) { } });
            }
        });
    }

    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);

    static bool Down(int vk)
    {
        return (GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    void Beep(int freq, int ms)
    {
        if (beep) ThreadPool.QueueUserWorkItem(delegate { Console.Beep(freq, ms); });
    }

    [STAThread]
    static void Main()
    {
        bool fresh;
        using (new Mutex(true, "Global\\dictate-ptt", out fresh))
        {
            if (!fresh) return;
            Application.EnableVisualStyles();
            try { Application.Run(new Dictate()); }
            catch (Exception ex) { Log("fatal: " + ex); throw; }
        }
    }
}

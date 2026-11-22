using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace AsideBridge {
public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public INPUTUNION u; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool GetWindowDisplayAffinity(IntPtr h, out uint a);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint f, bool inherit, uint access);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);

  const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
  const uint KEYEVENTF_KEYUP = 0x2, KEYEVENTF_UNICODE = 0x4;
  const uint MOUSEEVENTF_MOVE = 0x1, LDOWN = 0x2, LUP = 0x4, RDOWN = 0x8, RUP = 0x10, WHEEL = 0x800, HWHEEL = 0x1000, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;

  static bool dpiSet = false;
  public static void InitDpi() { if (!dpiSet) { try { SetProcessDPIAware(); } catch {} dpiSet = true; } }

  static void Send(params INPUT[] ins) { SendInput((uint)ins.Length, ins, Marshal.SizeOf(typeof(INPUT))); }
  static INPUT Key(ushort vk, ushort scan, uint flags) { var i = new INPUT(); i.type = INPUT_KEYBOARD; i.u.ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags }; return i; }
  static INPUT Mouse(uint flags, int x = 0, int y = 0, uint data = 0) { var i = new INPUT(); i.type = INPUT_MOUSE; i.u.mi = new MOUSEINPUT { dx = x, dy = y, dwFlags = flags, mouseData = data }; return i; }

  // Types any Unicode text (Hangul, emoji) directly - no IME involved.
  public static int TypeText(string text, int delayMs) {
    int n = 0;
    foreach (char c in text) {
      if (c == '\n') { Send(Key(0x0D, 0, 0), Key(0x0D, 0, KEYEVENTF_KEYUP)); }
      else if (c == '\r') { continue; }
      else if (c == '\t') { Send(Key(0x09, 0, 0), Key(0x09, 0, KEYEVENTF_KEYUP)); }
      else { Send(Key(0, c, KEYEVENTF_UNICODE), Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)); }
      n++; if (delayMs > 0) Thread.Sleep(delayMs);
    }
    return n;
  }
  // Key combo like "ctrl+shift+s", "enter", "alt+f4", "win+r"
  public static void Keys(string combo) {
    var parts = combo.ToLower().Split('+'); var vks = new List<ushort>();
    foreach (var p in parts) vks.Add(Vk(p.Trim()));
    var ins = new List<INPUT>();
    foreach (var v in vks) ins.Add(Key(v, 0, 0));
    for (int i = vks.Count - 1; i >= 0; i--) ins.Add(Key(vks[i], 0, KEYEVENTF_KEYUP));
    Send(ins.ToArray());
  }
  static ushort Vk(string k) {
    switch (k) {
      case "ctrl": case "control": return 0x11; case "shift": return 0x10; case "alt": return 0x12; case "win": return 0x5B;
      case "enter": case "return": return 0x0D; case "esc": case "escape": return 0x1B; case "tab": return 0x09; case "space": return 0x20;
      case "backspace": return 0x08; case "delete": case "del": return 0x2E; case "home": return 0x24; case "end": return 0x23;
      case "pageup": return 0x21; case "pagedown": return 0x22; case "left": return 0x25; case "up": return 0x26; case "right": return 0x27; case "down": return 0x28;
      case "hangul": case "hanyeong": return 0x15; case "hanja": return 0x19; case "printscreen": return 0x2C; case "insert": return 0x2D;
    }
    if (k.Length > 1 && k[0] == 'f') { int f; if (int.TryParse(k.Substring(1), out f) && f >= 1 && f <= 24) return (ushort)(0x70 + f - 1); }
    if (k.Length == 1) { char c = char.ToUpper(k[0]); if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return (ushort)c; }
    throw new ArgumentException("unknown key: " + k);
  }
  public static void Move(int x, int y) { InitDpi(); SetCursorPos(x, y); }
  public static void Click(int x, int y, string button, int count) {
    InitDpi(); SetCursorPos(x, y); Thread.Sleep(60);
    uint d = button == "right" ? RDOWN : LDOWN, u = button == "right" ? RUP : LUP;
    for (int i = 0; i < count; i++) { Send(Mouse(d), Mouse(u)); Thread.Sleep(70); }
  }
  public static void Drag(int x1, int y1, int x2, int y2) {
    InitDpi(); SetCursorPos(x1, y1); Thread.Sleep(80); Send(Mouse(LDOWN));
    for (int i = 1; i <= 20; i++) { SetCursorPos(x1 + (x2 - x1) * i / 20, y1 + (y2 - y1) * i / 20); Thread.Sleep(15); }
    Send(Mouse(LUP));
  }
  // positive = up
  public static void Scroll(int x, int y, int lines, int hlines) {
    InitDpi(); SetCursorPos(x, y); Thread.Sleep(40);
    if (lines != 0) Send(Mouse(WHEEL, 0, 0, (uint)(lines * 120)));
    if (hlines != 0) Send(Mouse(HWHEEL, 0, 0, (uint)(hlines * 120)));
  }

  public static bool InputDesktopAvailable() {  // false when locked / UAC secure desktop
    IntPtr h = OpenInputDesktop(0, false, 0x0100); if (h == IntPtr.Zero) return false; CloseDesktop(h); return true;
  }

  public static string Screenshot(string path, int x, int y, int w, int h) {
    InitDpi();
    if (w <= 0 || h <= 0) { x = GetSystemMetrics(76); y = GetSystemMetrics(77); w = GetSystemMetrics(78); h = GetSystemMetrics(79); }
    using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
      bmp.Save(path, ImageFormat.Png);
    }
    return x + "," + y + "," + w + "," + h;
  }

  public class Win { public long Handle; public string Title; public int Pid; public int X, Y, W, H; public bool Minimized; public uint Affinity; }
  public static List<Win> Windows() {
    InitDpi(); var list = new List<Win>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(512); GetWindowText(h, sb, 512); if (sb.Length == 0) return true;
      RECT r; GetWindowRect(h, out r); uint pid; GetWindowThreadProcessId(h, out pid); uint a = 0; GetWindowDisplayAffinity(h, out a);
      list.Add(new Win { Handle = h.ToInt64(), Title = sb.ToString(), Pid = (int)pid, X = r.Left, Y = r.Top, W = r.Right - r.Left, H = r.Bottom - r.Top, Minimized = IsIconic(h), Affinity = a });
      return true; }, IntPtr.Zero);
    return list;
  }
  public static bool Focus(long handle) {
    var h = new IntPtr(handle); if (IsIconic(h)) ShowWindow(h, 9);
    if (GetForegroundWindow() == h) return true;
    keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); // ALT tap lets SetForegroundWindow succeed (only when not already foreground)
    bool ok = SetForegroundWindow(h); Thread.Sleep(150); return ok && GetForegroundWindow() == h;
  }
}
}

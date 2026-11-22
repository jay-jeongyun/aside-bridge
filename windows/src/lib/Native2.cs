using System; using System.Runtime.InteropServices; using System.Drawing; using System.Drawing.Imaging;
namespace AsideBridge {
public static class Native2 {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [DllImport("kernel32.dll")] static extern uint GetTickCount();
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  public static long Foreground() { return GetForegroundWindow().ToInt64(); }
  public struct RECT { public int L, T, R, B; }
  public static uint LastInputTick() { var l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l); GetLastInputInfo(ref l); return l.dwTime; }
  public static uint Tick() { return GetTickCount(); }
  public static double IdleSeconds() { return (GetTickCount() - LastInputTick()) / 1000.0; }
  public static string CaptureWindow(long handle, string path) {
    try { SetProcessDPIAware(); } catch {}
    var h = new IntPtr(handle); RECT r; GetWindowRect(h, out r); int w = r.R - r.L, hh = r.B - r.T;
    if (w <= 0 || hh <= 0) throw new Exception("window has no size (minimized?)");
    using (var bmp = new Bitmap(w, hh)) { using (var g = Graphics.FromImage(bmp)) { var dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); } Save(bmp, path); }
    return r.L + "," + r.T + "," + w + "," + hh;
  }
  public static void Save(Bitmap b, string path) {
    if (path.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase)) {
      var enc = Array.Find(ImageCodecInfo.GetImageEncoders(), e => e.MimeType == "image/jpeg");
      var ps = new EncoderParameters(1); ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 60L); b.Save(path, enc, ps);
    } else b.Save(path, ImageFormat.Png);
  }
  public static void ToJpeg(string src, string dst) { using (var b = new Bitmap(src)) { Save(b, dst); } }
  public static void ToJpegScaled(string src, string dst, double scale) { using (var b = new Bitmap(src)) using (var s = new Bitmap(b, new Size(Math.Max(1, (int)(b.Width * scale)), Math.Max(1, (int)(b.Height * scale))))) { Save(s, dst); } }
  public static double DiffPercent(string a, string b) {
    using (var x = new Bitmap(a)) using (var y = new Bitmap(b)) using (var xs = new Bitmap(x, new Size(64, 64))) using (var ys = new Bitmap(y, new Size(64, 64))) {
      int d = 0; for (int j = 0; j < 64; j++) for (int i = 0; i < 64; i++) { var p = xs.GetPixel(i, j); var q = ys.GetPixel(i, j); if (Math.Abs(p.R - q.R) + Math.Abs(p.G - q.G) + Math.Abs(p.B - q.B) > 60) d++; }
      return d / 4096.0 * 100.0; }
  }
  public static double DarkPercent(string a) {
    using (var x = new Bitmap(a)) using (var xs = new Bitmap(x, new Size(32, 32))) { int d = 0; for (int j = 0; j < 32; j++) for (int i = 0; i < 32; i++) { var p = xs.GetPixel(i, j); if (p.R + p.G + p.B < 30) d++; } return d / 1024.0 * 100.0; }
  }
}}
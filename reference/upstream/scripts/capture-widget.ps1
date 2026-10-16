# Screenshot the mini card, which the app keeps hidden until the user enables widget mode.
#
# The window is revealed with ShowWindow rather than through the app's own toggle because the
# toggle is only reachable from the tray menu or a global shortcut, neither of which can be
# driven while another window holds the foreground. Its previous visibility is restored after.

param([string]$Out = "$env:TEMP\glassusage-widget.png")

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinW {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static IntPtr Find(uint pid, string title) {
        IntPtr hit = IntPtr.Zero;
        EnumWindows((h, p) => {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (wpid != pid) return true;
            var sb = new StringBuilder(512);
            GetWindowTextW(h, sb, sb.Capacity);
            if (sb.ToString() == title) { hit = h; return false; }
            return true;
        }, IntPtr.Zero);
        return hit;
    }
}
"@

$proc = Get-Process glassusage -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { Write-Output "app is not running"; exit 1 }

$h = [WinW]::Find([uint32]$proc.Id, "GlassUsage Mini")
if ($h -eq [IntPtr]::Zero) { Write-Output "mini card window not found"; exit 1 }

$wasVisible = [WinW]::IsWindowVisible($h)
if (-not $wasVisible) {
    [WinW]::ShowWindow($h, 8) | Out-Null   # SW_SHOWNA - reveal without taking focus
    Start-Sleep -Milliseconds 1200
}

$r = New-Object WinW+RECT
[WinW]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null
$w = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top

$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[WinW]::PrintWindow($h, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

if (-not $wasVisible) { [WinW]::ShowWindow($h, 0) | Out-Null }   # SW_HIDE

Write-Output "saved $Out (${w}x${ht}, restored hidden=$(-not $wasVisible))"

# Screenshot a window of the running app.
#
# Captures the screen region the window occupies rather than using PrintWindow, because the
# acrylic backdrop is composited by the OS from what sits behind the window - PrintWindow
# would return only the window's own layers and lose the effect being verified.
#
# The app owns two top-level windows (main and the mini card), and the hidden one must not
# be picked, so windows are enumerated and matched on title and visibility.

param(
    [string]$ProcessName = "glassusage",
    [string]$TitleMatch = "GlassUsage",
    [string]$Out = "$env:TEMP\glassusage-shot.png",
    [int]$SettleMs = 1500,
    [switch]$List,
    # Capture the window's own layers instead of the screen region. Necessary when another
    # window is on top, since Windows refuses to let a background process take foreground.
    # The native acrylic backdrop is not part of the window, so it comes out transparent.
    [switch]$Direct,
    [switch]$KeepOnTop
)

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class Win {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    static readonly IntPtr TOPMOST = new IntPtr(-1);
    static readonly IntPtr NOTOPMOST = new IntPtr(-2);
    const uint NOMOVE = 0x0002, NOSIZE = 0x0001, NOACTIVATE = 0x0010;

    // Raising by z-order works from a background process, unlike SetForegroundWindow, and
    // leaves the user's focus where it was.
    public static void Raise(IntPtr h, bool on) {
        SetWindowPos(h, on ? TOPMOST : NOTOPMOST, 0, 0, 0, 0, NOMOVE | NOSIZE | NOACTIVATE);
    }

    public static List<IntPtr> TopLevel(uint pid) {
        var found = new List<IntPtr>();
        EnumWindows((h, p) => {
            uint wpid; GetWindowThreadProcessId(h, out wpid);
            if (wpid == pid) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string Title(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@

$procs = Get-Process $ProcessName -ErrorAction SilentlyContinue
if (-not $procs) { Write-Output "process '$ProcessName' is not running"; exit 1 }

$candidates = @()
foreach ($p in $procs) {
    foreach ($h in [Win]::TopLevel([uint32]$p.Id)) {
        $title = [Win]::Title($h)
        if (-not $title) { continue }
        $r = New-Object Win+RECT
        if ([Win]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) -ne 0) { continue }
        $candidates += [pscustomobject]@{
            Handle  = $h
            Title   = $title
            Visible = [Win]::IsWindowVisible($h)
            X = $r.Left; Y = $r.Top
            W = $r.Right - $r.Left
            H = $r.Bottom - $r.Top
        }
    }
}

if ($List) {
    $candidates | Format-Table -AutoSize | Out-String | Write-Output
    exit 0
}

# Prefer a visible window whose title matches, then simply the largest visible one.
$target = $candidates |
    Where-Object { $_.Visible -and $_.W -gt 200 -and $_.H -gt 200 -and $_.Title -like "*$TitleMatch*" } |
    Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
if (-not $target) {
    $target = $candidates |
        Where-Object { $_.Visible -and $_.W -gt 200 -and $_.H -gt 200 } |
        Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1
}
if (-not $target) {
    Write-Output "no visible window found; candidates were:"
    $candidates | Format-Table -AutoSize | Out-String | Write-Output
    exit 1
}

$bmp = New-Object System.Drawing.Bitmap $target.W, $target.H
$g = [System.Drawing.Graphics]::FromImage($bmp)

if ($Direct) {
    # PW_RENDERFULLCONTENT (2) is what makes this work for a Chromium/WebView2 surface.
    $hdc = $g.GetHdc()
    $ok = [Win]::PrintWindow($target.Handle, $hdc, 2)
    $g.ReleaseHdc($hdc)
    if (-not $ok) { Write-Output "PrintWindow failed" }
} else {
    # The acrylic backdrop is drawn by the compositor from whatever sits behind the window,
    # so it only appears in a real screen grab, which needs the window unobstructed.
    [Win]::ShowWindow($target.Handle, 9) | Out-Null   # SW_RESTORE
    [Win]::Raise($target.Handle, $true)
    Start-Sleep -Milliseconds $SettleMs
    $g.CopyFromScreen($target.X, $target.Y, 0, 0, $bmp.Size)
    if (-not $KeepOnTop) { [Win]::Raise($target.Handle, $false) }
}

$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Output "saved $Out  ('$($target.Title)' $($target.W)x$($target.H))"

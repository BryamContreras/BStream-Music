param(
  [Parameter(Mandatory = $true)][int]$TargetProcessId,
  [ValidateSet('Inspect', 'Capture', 'Resize', 'Click', 'ScrollTop', 'WheelSweep', 'HorizontalDrag', 'Tabs')][string]$Action = 'Inspect',
  [ValidateRange(640, 5000)][int]$Width = 1280,
  [ValidateRange(480, 3000)][int]$Height = 720,
  [int]$X = 700,
  [int]$Y = 350,
  [int]$EndX = 350,
  [int]$EndY = 350,
  [ValidateRange(1, 10)][int]$Cycles = 3,
  [ValidateRange(1, 60)][int]$Steps = 10,
  [ValidateRange(10, 200)][int]$StepMs = 45,
  [ValidateRange(1, 120)][int]$WheelDelta = 60,
  [string]$TapSequence = '[]',
  [string]$ReportPath,
  [string]$ScreenshotPath,
  [switch]$OneWay,
  [switch]$Maximize
)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BStreamDesktopInput {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
  [DllImport("user32.dll")] static extern bool AdjustWindowRectEx(ref RECT r, uint style, bool menu, uint exStyle);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int width, int height, uint flags);
  public static void ResizeClient(IntPtr h, int width, int height) {
    ShowWindow(h, 9);
    var r = new RECT { Right = width, Bottom = height };
    if (!AdjustWindowRectEx(ref r, unchecked((uint)GetWindowLong(h, -16)), false, unchecked((uint)GetWindowLong(h, -20)))) throw new InvalidOperationException("Cannot resolve app window frame");
    if (!SetWindowPos(h, IntPtr.Zero, 40, 40, r.Right - r.Left, r.Bottom - r.Top, 4)) throw new InvalidOperationException("Cannot resize app window");
  }
  [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateWaitableTimerEx(IntPtr attributes, string name, uint flags, uint access);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetWaitableTimer(IntPtr timer, ref long dueTime, int period, IntPtr callback, IntPtr arg, bool resume);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  static IntPtr timer;
  public static void PreciseSleep(int ms) {
    if (timer == IntPtr.Zero) {
      timer = CreateWaitableTimerEx(IntPtr.Zero, null, 2, 0x1F0003);
      if (timer == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    long due = -(long)ms * 10000;
    if (!SetWaitableTimer(timer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    if (WaitForSingleObject(timer, 5000) != 0) throw new InvalidOperationException("Input timer wait failed");
  }
  public static void DisposeTimer() { if (timer != IntPtr.Zero) { CloseHandle(timer); timer = IntPtr.Zero; } }
  public static void LeftDown() { mouse_event(2, 0, 0, 0, UIntPtr.Zero); }
  public static void LeftUp() { mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
  public static void Wheel(int delta) { mouse_event(0x800, 0, 0, unchecked((uint)delta), UIntPtr.Zero); }
}
'@

$appProcess = Get-Process -Id $TargetProcessId
if ($appProcess.ProcessName -ne 'bstream_music') { throw 'Only the BStream desktop process may receive this tool input.' }
$appProcess.Refresh()
$windowHandle = $appProcess.MainWindowHandle
if ($windowHandle -eq [IntPtr]::Zero) { throw 'BStream has no visible main window.' }
if ($Maximize) { [void][BStreamDesktopInput]::ShowWindow($windowHandle, 3) }
if ($Action -eq 'Resize') { [BStreamDesktopInput]::ResizeClient($windowHandle, $Width, $Height) }
if ($Action -ne 'Inspect') {
  [void][BStreamDesktopInput]::SetForegroundWindow($windowHandle)
  Start-Sleep -Milliseconds 250
}
$clientRect = New-Object BStreamDesktopInput+RECT
[void][BStreamDesktopInput]::GetClientRect($windowHandle, [ref]$clientRect)
$clientOrigin = New-Object BStreamDesktopInput+POINT
[void][BStreamDesktopInput]::ClientToScreen($windowHandle, [ref]$clientOrigin)
$windowRect = New-Object BStreamDesktopInput+RECT
[void][BStreamDesktopInput]::GetWindowRect($windowHandle, [ref]$windowRect)
$windows = New-Object 'System.Collections.Generic.List[object]'
function Get-Marker {
  return @{
    unixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    qpcMs = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency
  }
}
function Assert-Foreground {
  [uint32]$foregroundProcessId = 0
  [void][BStreamDesktopInput]::GetWindowThreadProcessId([BStreamDesktopInput]::GetForegroundWindow(), [ref]$foregroundProcessId)
  if ($foregroundProcessId -ne $TargetProcessId) { throw 'Input stopped: BStream is no longer foreground.' }
}
function Move-WithinApp([int]$clientX, [int]$clientY) {
  Assert-Foreground
  if ($clientX -lt 0 -or $clientY -lt 0 -or $clientX -ge $clientRect.Right -or $clientY -ge $clientRect.Bottom) {
    throw 'Input coordinate is outside the BStream client area.'
  }
  [void][BStreamDesktopInput]::SetCursorPos($clientOrigin.X + $clientX, $clientOrigin.Y + $clientY)
}
function Add-Window($start, $end, [string]$label, $inputTimes = @()) {
  $windows.Add(@{
    label = $label; startUnixMs = $start.unixMs; endUnixMs = $end.unixMs
    startQpcMs = $start.qpcMs; endQpcMs = $end.qpcMs
    inputQpcMs = @($inputTimes); requestedStepMs = $StepMs
  })
}
function Click-WithinApp([int]$clientX, [int]$clientY) {
  Move-WithinApp $clientX $clientY
  [BStreamDesktopInput]::LeftDown()
  try { Start-Sleep -Milliseconds 15 } finally { [BStreamDesktopInput]::LeftUp() }
}

switch ($Action) {
  'Click' { Click-WithinApp $X $Y }
  'ScrollTop' {
    Move-WithinApp $X $Y
    for ($step = 0; $step -lt $Steps; $step++) {
      Assert-Foreground
      [BStreamDesktopInput]::Wheel(120)
      [BStreamDesktopInput]::PreciseSleep($StepMs)
    }
    Start-Sleep -Milliseconds 500
  }
  'WheelSweep' {
    for ($cycle = 0; $cycle -lt $Cycles; $cycle++) {
      foreach ($direction in @(-1, 1)) {
        Move-WithinApp $X $Y
        $start = Get-Marker
        $inputTimes = New-Object 'System.Collections.Generic.List[double]'
        for ($step = 0; $step -lt $Steps; $step++) {
          Assert-Foreground
          $inputTimes.Add((Get-Marker).qpcMs)
          [BStreamDesktopInput]::Wheel($direction * $WheelDelta)
          [BStreamDesktopInput]::PreciseSleep($StepMs)
        }
        Add-Window $start (Get-Marker) "wheel-$cycle-$direction" $inputTimes.ToArray()
        Start-Sleep -Milliseconds 120
        Start-Sleep -Milliseconds 180
      }
    }
  }
  'HorizontalDrag' {
    for ($cycle = 0; $cycle -lt $Cycles; $cycle++) {
      $directions = if ($OneWay) { ,$false } else { @($false, $true) }
      foreach ($reverse in $directions) {
        $fromX = if ($reverse) { $EndX } else { $X }
        $toX = if ($reverse) { $X } else { $EndX }
        Move-WithinApp $fromX $Y
        $start = Get-Marker
        $inputTimes = New-Object 'System.Collections.Generic.List[double]'
        [BStreamDesktopInput]::LeftDown()
        try {
          for ($step = 1; $step -le $Steps; $step++) {
            Move-WithinApp ([int]($fromX + ($toX - $fromX) * $step / $Steps)) $Y
            $inputTimes.Add((Get-Marker).qpcMs)
            [BStreamDesktopInput]::PreciseSleep($StepMs)
          }
        } finally { [BStreamDesktopInput]::LeftUp() }
        Add-Window $start (Get-Marker) "drag-$cycle-$reverse" $inputTimes.ToArray()
        Start-Sleep -Milliseconds 120
        Start-Sleep -Milliseconds 180
      }
    }
  }
  'Tabs' {
    $points = ConvertFrom-Json -InputObject $TapSequence
    if ($points.Count -lt 1 -or $points.Count -gt 12) { throw 'Supply 1 to 12 tab coordinates.' }
    for ($cycle = 0; $cycle -lt $Cycles; $cycle++) {
      foreach ($point in $points) {
        if ($point.Count -ne 2) { throw 'Each tab coordinate must be [x,y].' }
        Move-WithinApp $point[0] $point[1]
        [BStreamDesktopInput]::LeftDown()
        Start-Sleep -Milliseconds 15
        $start = Get-Marker
        [BStreamDesktopInput]::LeftUp()
        Start-Sleep -Milliseconds 360
        Add-Window $start (Get-Marker) "tab-$cycle-$($point[0])-$($point[1])"
        Start-Sleep -Milliseconds 290
      }
    }
  }
}
if ($ScreenshotPath) {
  Add-Type -AssemblyName System.Drawing
  $bitmap = New-Object Drawing.Bitmap ($windowRect.Right - $windowRect.Left), ($windowRect.Bottom - $windowRect.Top)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen($windowRect.Left, $windowRect.Top, 0, 0, $bitmap.Size)
    $bitmap.Save([IO.Path]::GetFullPath($ScreenshotPath), [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
if ($ReportPath) {
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), (ConvertTo-Json -InputObject @($windows.ToArray()) -Depth 5))
}
[BStreamDesktopInput]::DisposeTimer()
@{
  processId = $TargetProcessId; action = $Action; clientWidth = $clientRect.Right; clientHeight = $clientRect.Bottom
  screenOriginX = $clientOrigin.X; screenOriginY = $clientOrigin.Y; motionWindows = @($windows.ToArray())
} | ConvertTo-Json -Depth 5

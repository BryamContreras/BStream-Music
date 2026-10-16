# Read a scoped per-frame query through an ALREADY RUNNING PresentMon service.
# No elevation, ETW-session creation, service/ACL changes or UI input.
# ApiPath must be the matching installed PresentMonAPI2.dll (or an exact copy).
# Start motion only after BSTREAM_NATIVE_READY; preserve idle gaps in raw output.
# API definitions: https://github.com/GameTechDev/PresentMon/blob/main/IntelPresentMon/PresentMonAPI2/PresentMonAPI.h
param(
  [Parameter(Mandatory = $true)][int]$ProcessId,
  [Parameter(Mandatory = $true)][string]$ApiPath,
  [Parameter(Mandatory = $true)][string]$Out,
  [ValidateRange(1, 120)][int]$Seconds = 15,
  [string]$ControlPipe = '\\.\pipe\pm2_igs'
)
$ErrorActionPreference = 'Stop'
$target = Get-Process -Id $ProcessId -ErrorAction Stop
if ($target.ProcessName -ne 'bstream_music') { throw 'Capture is restricted to a bstream_music process' }
$apiFullPath = (Resolve-Path -LiteralPath $ApiPath).Path
if ([IO.Path]::GetFileName($apiFullPath) -ne 'PresentMonAPI2.dll') { throw 'Expected the installed PresentMonAPI2.dll' }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class BStreamPresentCapture : IDisposable {
  [StructLayout(LayoutKind.Sequential)] public struct Element {
    public int metric, stat;
    public uint deviceId, arrayIndex;
    public ulong dataOffset, dataSize;
  }
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Open(out IntPtr h, [MarshalAs(UnmanagedType.LPStr)] string pipe);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Close(IntPtr h);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Track(IntPtr h, uint id);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Intro(IntPtr h, out IntPtr root);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Register(IntPtr h, out IntPtr query, [In, Out] Element[] elements, ulong count, out uint blobSize);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Consume(IntPtr h, uint id, IntPtr data, ref uint count);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibrary(string path);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)] static extern IntPtr GetProcAddress(IntPtr library, string name);
  [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr library);
  readonly IntPtr library;
  IntPtr session, query, buffer;
  readonly Close close, freeQuery, freeIntro;
  readonly Track startTracking, stopTracking;
  readonly Consume consume;
  readonly uint processId;
  bool tracking;
  Element[] elements;
  readonly string[] names = { "swapChain", "cpuStartQpc", "presentStartQpc", "displayedTimeMs", "displayLatencyMs", "untilDisplayedMs", "betweenPresentsMs", "betweenDisplayChangeMs", "cpuFrameTimeMs", "presentMode", "presentRuntime", "frameType", "cpuBusyMs", "cpuWaitMs", "gpuTimeMs", "gpuBusyMs", "gpuWaitMs", "inPresentApiMs" };
  readonly int[] ids = { 1, 7, 77, 17, 24, 81, 78, 80, 8, 20, 21, 63, 9, 10, 13, 14, 15, 79 };
  int[] dataTypes;
  uint blobSize;
  public int FullBatches { get; private set; }
  public List<Dictionary<string, object>> Frames = new List<Dictionary<string, object>>();
  public Dictionary<string, object> Metadata = new Dictionary<string, object>();
  static double QpcMs() { return Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency; }
  T Function<T>(string name) where T : class {
    IntPtr pointer = GetProcAddress(library, name);
    if (pointer == IntPtr.Zero) throw new InvalidOperationException("Missing PresentMon API endpoint " + name);
    return Marshal.GetDelegateForFunctionPointer(pointer, typeof(T)) as T;
  }
  static void Check(int code, string operation) {
    if (code != 0) throw new InvalidOperationException(operation + " failed with PM_STATUS=" + code);
  }
  public BStreamPresentCapture(string path, string pipe, uint id) {
    processId = id;
    library = LoadLibrary(path);
    if (library == IntPtr.Zero) throw new InvalidOperationException("Cannot load matching PresentMon API; Win32 error " + Marshal.GetLastWin32Error());
    close = Function<Close>("pmCloseSession");
    freeQuery = Function<Close>("pmFreeFrameQuery");
    freeIntro = Function<Close>("pmFreeIntrospectionRoot");
    startTracking = Function<Track>("pmStartTrackingProcess");
    stopTracking = Function<Track>("pmStopTrackingProcess");
    consume = Function<Consume>("pmConsumeFrames");
    try {
      Check(Function<Open>("pmOpenSessionWithPipe")(out session, pipe), "Open service session");
      IntPtr root;
      Check(Function<Intro>("pmGetIntrospectionRoot")(session, out root), "Introspect metrics");
      try {
        IntPtr metrics = Marshal.ReadIntPtr(root);
        IntPtr array = Marshal.ReadIntPtr(metrics);
        long count = Marshal.ReadIntPtr(metrics, IntPtr.Size).ToInt64();
        if (count < 1 || count > 1000) throw new InvalidOperationException("Invalid introspection metric count");
        var metricTypes = new Dictionary<int,int>();
        for (int i = 0; i < count; i++) {
          IntPtr metric = Marshal.ReadIntPtr(array, i * IntPtr.Size);
          int metricId = Marshal.ReadInt32(metric);
          IntPtr typeInfo = Marshal.ReadIntPtr(metric, 16);
          metricTypes[metricId] = Marshal.ReadInt32(typeInfo, 4); // frameType, not polledType
        }
        elements = new Element[ids.Length];
        dataTypes = new int[ids.Length];
        for (int i = 0; i < ids.Length; i++) {
          int type;
          if (!metricTypes.TryGetValue(ids[i], out type) || type == 7) throw new InvalidOperationException("Required native frame metric unavailable: " + names[i]);
          elements[i].metric = ids[i];
          dataTypes[i] = type;
        }
      } finally { Check(freeIntro(root), "Free introspection"); }
      Check(Function<Register>("pmRegisterFrameQuery")(session, out query, elements, (ulong)elements.Length, out blobSize), "Register per-frame query");
      if (blobSize < 1 || blobSize > 4096) throw new InvalidOperationException("Unsafe frame blob size");
      foreach (Element element in elements) if (element.dataOffset + element.dataSize > blobSize) throw new InvalidOperationException("Invalid metric offset");
      buffer = Marshal.AllocHGlobal(checked((int)blobSize * 2048));
      Check(startTracking(session, id), "Start scoped process tracking");
      tracking = true;
      Metadata["processId"] = id;
      Metadata["qpcFrequency"] = Stopwatch.Frequency;
      Metadata["metricNames"] = names;
      Metadata["metricIds"] = ids;
      Metadata["metricTypes"] = dataTypes;
      Metadata["blobSize"] = blobSize;
    } catch { Dispose(); throw; }
  }
  public void Poll() {
    for (int batch = 0; batch < 32; batch++) {
      uint count = 2048;
      Check(consume(query, processId, buffer, ref count), "Consume native frames");
      if (count > 2048) throw new InvalidOperationException("Native API overflowed requested capacity");
      for (int row = 0; row < count; row++) {
        IntPtr frame = IntPtr.Add(buffer, checked(row * (int)blobSize));
        var values = new Dictionary<string, object>();
        for (int i = 0; i < elements.Length; i++) {
          IntPtr value = IntPtr.Add(frame, checked((int)elements[i].dataOffset));
          switch (dataTypes[i]) {
            case 0:
              double number = Marshal.PtrToStructure<double>(value);
              // Missing native display metrics are NaN. PowerShell 5 emits
              // bare NaN (invalid JSON), so retain absence explicitly as null.
              values[names[i]] = Double.IsNaN(number) || Double.IsInfinity(number) ? null : (object)number;
              break;
            case 1: case 3: values[names[i]] = Marshal.ReadInt32(value); break;
            case 2: values[names[i]] = unchecked((uint)Marshal.ReadInt32(value)); break;
            case 5: values[names[i]] = unchecked((ulong)Marshal.ReadInt64(value)); break;
            case 6: values[names[i]] = Marshal.ReadByte(value) != 0; break;
            default: throw new InvalidOperationException("Unexpected native frame metric data type");
          }
        }
        values["readQpcMs"] = QpcMs();
        Frames.Add(values);
      }
      if (count < 2048) return;
      FullBatches++;
    }
    throw new InvalidOperationException("Native frame queue did not drain; capture coverage is unreliable");
  }
  public void Dispose() {
    if (tracking) { stopTracking(session, processId); tracking = false; }
    if (query != IntPtr.Zero) { freeQuery(query); query = IntPtr.Zero; }
    if (session != IntPtr.Zero) { close(session); session = IntPtr.Zero; }
    if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero; }
    if (library != IntPtr.Zero) FreeLibrary(library);
  }
}
'@
$capture = $null
try {
  $capture = New-Object BStreamPresentCapture($apiFullPath, $ControlPipe, $ProcessId)
  # Drain initial data before publishing the actual capture interval.
  $capture.Poll()
  $startQpcMs = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency
  Write-Output "BSTREAM_NATIVE_READY $startQpcMs"
  $timer = [Diagnostics.Stopwatch]::StartNew()
  while ($timer.Elapsed.TotalSeconds -lt $Seconds) { $capture.Poll(); Start-Sleep -Milliseconds 50 }
  $endQpcMs = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency
  # This installed service can deliver native events ~1.5 seconds after present.
  # Drain beyond that delay; do not change the service's global flush settings.
  $drainTimer = [Diagnostics.Stopwatch]::StartNew()
  while ($drainTimer.ElapsedMilliseconds -lt 3000) { $capture.Poll(); Start-Sleep -Milliseconds 50 }
  $result = [ordered]@{
    source = 'existing-PresentMon-service-frame-query'
    nativePresentationMeasured = $true
    caveat = 'Per-app native present/display metrics; analyze only verified motion windows and per-swapchain. Idle intervals are not dropped frames. Non-displayed frames have no valid display timestamp.'
    startQpcMs = $startQpcMs
    endQpcMs = $endQpcMs
    fullBatches = $capture.FullBatches
    metadata = $capture.Metadata
    frames = $capture.Frames
  }
  $outputPath = [IO.Path]::GetFullPath($Out)
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($outputPath)) -Force | Out-Null
  $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputPath -Encoding UTF8
  Write-Output "BSTREAM_NATIVE_DONE frames=$($capture.Frames.Count) fullBatches=$($capture.FullBatches) output=$outputPath"
} finally { if ($null -ne $capture) { $capture.Dispose() } }

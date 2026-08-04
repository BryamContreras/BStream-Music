# Windows tools

Put the required desktop download tools here:

- `yt-dlp.exe`
- `deno.exe` (Deno 2.3 or newer)

The optional TikTok LIVE bridge may also be placed here:

- `tiktok-live-bridge/tiktok_live_bridge.exe`

When building the Windows app, this folder is copied next to `bstream_music.exe`.
The desktop downloader passes the bundled Deno executable explicitly to
`yt-dlp` so YouTube JavaScript challenges work without requiring a system
runtime. A supported Node installation remains a development fallback. The
TikTok LIVE integration uses the bundled bridge before falling back to the
development Python script.

Release builds currently provision and checksum Deno 2.9.4 automatically.

These binaries and the generated `tiktok-live-bridge/` runtime are intentionally
ignored by Git. Rebuild the bridge from the project root with:

```powershell
.\scripts\build_tiktok_bridge.ps1 -Jobs 28
```

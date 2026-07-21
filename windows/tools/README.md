# Windows tools

Put optional desktop binaries here:

- `yt-dlp.exe`
- `ffmpeg.exe`
- `tiktok-live-bridge/tiktok_live_bridge.exe`

`ffmpeg.exe` can also live at `windows/tools/ffmpeg/bin/ffmpeg.exe`.

When building the Windows app, this folder is copied next to `bstream_music.exe`.
The desktop downloader will search it before falling back to the system `PATH`,
and the TikTok LIVE integration will use the bundled bridge before falling back
to the development Python script.

These binaries and the generated `tiktok-live-bridge/` runtime are intentionally
ignored by Git. Rebuild the bridge from the project root with:

```powershell
.\scripts\build_tiktok_bridge.ps1 -Jobs 28
```

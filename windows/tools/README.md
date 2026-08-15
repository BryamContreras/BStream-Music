# Windows tools

Put the required desktop download tools here:

- `yt-dlp.exe`
- `deno.exe` (Deno 2.3 or newer)

When building the Windows app, this folder is copied next to `bstream_music.exe`.
The desktop downloader passes the bundled Deno executable explicitly to
`yt-dlp` so YouTube JavaScript challenges work without requiring a system
runtime. A supported Node installation remains a development fallback. TikTok
LIVE is implemented directly in Dart and does not require an external tool.

Release builds currently provision and checksum Deno 2.9.4 automatically.

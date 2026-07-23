# macOS tools

Release and Profile builds require these executable files:

- `yt-dlp` (or `yt-dlp_macos`)
- `ffmpeg` (or `ffmpeg/bin/ffmpeg`)

The Xcode build phase copies them into:

```text
bstream_music.app/Contents/Resources/tools/
```

The copied executables are renamed to `yt-dlp` and `ffmpeg` and receive
executable permissions. Xcode signs FFmpeg with the application. The official
`yt-dlp_macos` executable is a PyInstaller onefile archive, so its existing
signature and bytes must be preserved; post-signing only its launcher breaks
the embedded Python runtime on macOS. FFmpeg is always resolved from a bundled
`tools` directory; BStream does not fall back to the system FFmpeg installation.

Use native macOS binaries compatible with the architectures you distribute.
For a universal app, both tools must support Apple Silicon (`arm64`) and Intel
(`x86_64`), or be universal binaries themselves.

The binaries are intentionally excluded from Git. Place verified copies in this
folder before running:

```bash
flutter build macos --release
```

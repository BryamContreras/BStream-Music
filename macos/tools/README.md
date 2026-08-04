# macOS tools

Release and Profile builds require these executable files:

- `yt-dlp` (or `yt-dlp_macos`)
- `deno` (Deno 2.3 or newer)

The Xcode build phase copies them into:

```text
bstream_music.app/Contents/Resources/tools/
```

The copied executables receive executable permissions. Deno is passed
explicitly to `yt-dlp` to solve YouTube JavaScript challenges and is signed with
the application. The official `yt-dlp_macos` executable is a PyInstaller
onefile archive, so its existing signature and bytes must be preserved;
post-signing only its launcher breaks the embedded Python runtime on macOS.

Use native macOS binaries compatible with the architectures you distribute. For
a universal app, both tools must support Apple Silicon (`arm64`) and Intel
(`x86_64`), or be universal binaries themselves.

The binaries are intentionally excluded from Git. Release builds currently pin
and checksum Deno 2.9.4. Place verified copies in this folder before running:

```bash
flutter build macos --release
```

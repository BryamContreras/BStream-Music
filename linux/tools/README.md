# Linux tools

Release bundles expect executable copies of:

- `yt-dlp` (or `yt-dlp_linux`)
- `ffmpeg` (or `ffmpeg/bin/ffmpeg`)

Place verified x86_64 Linux binaries in this directory before building. CMake
copies the complete `tools` directory next to `bstream_music`, and the desktop
downloader resolves FFmpeg only from that bundled location.

GitHub Actions provisions both tools automatically. The binaries are excluded
from Git and are published only inside generated workflow artifacts.

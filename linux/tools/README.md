# Linux tools

Release bundles require executable copies of:

- `yt-dlp` (or `yt-dlp_linux`)
- `deno` (Deno 2.3 or newer)

Place verified x86_64 Linux binaries in this directory before building. Deno is
passed explicitly to `yt-dlp` to solve YouTube JavaScript challenges. CMake
copies the complete `tools` directory next to `bstream_music`.

GitHub Actions provisions both tools automatically. The binaries are excluded
from Git and are published only inside generated workflow artifacts. Release
builds currently pin and checksum Deno 2.9.4.

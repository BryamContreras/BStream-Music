# BStream Music

BStream Music is a cross-platform music player and library manager built with Flutter. It lets you search for music, play and download tracks, organize a local library, and manage playlists on Android, Windows, Linux, and macOS.

Current version: **1.2.1+121**.

> The repository does not store media content or third-party binaries. CI-generated desktop installers download and bundle verified copies of `yt-dlp` and Deno. Users are responsible for complying with copyright laws, provider terms, and the licenses of these tools.

<img width="1317" height="774" alt="imagen" src="https://github.com/user-attachments/assets/40e3057f-dfa0-4c51-aa40-905195e81e99" /> <img width="1317" height="770" alt="Capture1" src="https://github.com/user-attachments/assets/b86973f9-c578-444a-b474-3ca1842c56d6" />



## Main features

### Search, downloads, and library

- Search results with thumbnail, title, artist/channel, and duration.
- Remote playback and audio downloads with real-time progress.
- SQLite-backed local library.
- Reuse of downloaded tracks to avoid duplicate downloads.
- Filtering, renaming, and deletion of saved tracks.
- Playlist creation, renaming, and deletion.
- Dedicated **Favorites** playlist with a visible star on favorited tracks.
- ZIP backup and restore for the database, audio files, and thumbnails.

### Player

- Play, pause, previous, next, repeat, and shuffle controls.
- Playback queue synchronized with playlists and the library.
- Queue side panel on Windows and a dedicated queue view on Android.
- Change tracks directly from the queue.
- The active track is highlighted with a segmented 13-bar equalizer.
- Dark dynamic background derived from the track artwork.
- Animated progress bar with waves and artwork-derived color.
- Direct volume control beside the repeat button.
- Synchronized lyrics powered by LRCLIB, with plain-lyrics fallback, automatic
  scrolling, tap-to-seek, and a manual timing offset from `-10` to `+10` seconds
  in `0.50`-second steps.
- Sleep timer with quick durations and a custom duration.
- Native system media integration: Android media notifications, Windows
  SMTC, Linux MPRIS, and macOS Now Playing.
- Windows registers a stable application identity so SMTC shows the BStream
  Music name and icon in system media controls.
- Failed-track handling: a track that cannot be downloaded or played does not leave the queue stuck on the previous track.

### Interface

- Responsive layouts for Android and Windows.
- Navigation remembers only the two most recent views.
- Returning from the player restores the previously opened playlist or section.
- Home displays up to 10 recently played items and 10 playlists.
- Subtle gradients, translucent cards, and shared visual controls.
- Spanish and English selectable from Settings.
- Windows window minimum size of `960 × 600`; the player progressively adapts artwork, text, spacing, and controls to the available height.
- Icons generated from one source asset for Android, Windows, macOS, and Flutter resources.

## TikTok LIVE on Windows

The Windows version can connect to a LIVE through a bridge based on `TikTokLive` and turn chat commands into a temporary music queue.

Available features:

- Connect using `@username` or `https://www.tiktok.com/@username/live`.
- Detect the user who requested each track.
- Identify moderators.
- Configure command permissions for **Everyone** or **Moderators only**.
- LIVE queue states for searching, downloading, ready, and failed requests.
- Reuse tracks that already exist in the library.
- Dynamic synchronization: new requests are added without replacing the current playback.
- Automatically skip requests that fail during download.

Recognized commands:

```text
!play song name
!skip
!next
!revoke
!stop
revoke!
```

`!play` searches for the first result, prepares it, and adds it to the queue. `!skip`/`!next` advance playback, while `!revoke`/`!stop` clear the LIVE queue.

This integration uses an unofficial library. If TikTok changes its protocol, the bridge may need to be updated.

## Platforms and engines

| Platform | Player | Downloads | Notes |
| --- | --- | --- | --- |
| Android | `just_audio` + `audio_service` | `youtubedl-android` + QuickJS | `minSdk 24`; Release APKs support `arm64-v8a` and `x86_64` |
| Windows | `media_kit` | Bundled `yt-dlp` + Deno | SMTC controls, TikTok LIVE, queue side panel, and external tools |
| Linux | `media_kit` | Bundled `yt-dlp` + Deno | MPRIS controls; Ubuntu 22.04-based x64 installers; requires GTK 3, libmpv, and SQLite |
| macOS | `media_kit` | Bundled `yt-dlp` + Deno | Now Playing controls; separate PKG installers for Apple Silicon and Intel; minimum window `960 × 600` |

Downloads and remote playback use the same native-audio selection policy on
every platform: prefer the best available M4A/AAC stream, otherwise use the
best original audio stream. BStream preserves the source container and does
not extract, remux, transcode, or embed tags/artwork. Library metadata is kept
in SQLite and artwork is saved as a separate thumbnail file.

BStream does not invoke or bundle standalone `ffmpeg` or `ffprobe`
executables. Desktop playback still relies on the codec libraries included by
`media_kit`/libmpv; those libraries decode M4A, Opus, and other formats during
playback, but they are not a transcoding or download post-processing step.

Lyrics are requested from [LRCLIB](https://lrclib.net) only when the lyrics
view is opened. BStream sends the current title, artist, duration, and album
when available, identifies itself with the required client header, and keeps a
short in-memory cache to avoid duplicate requests. Lyrics are not embedded in
downloaded audio files.

## Architecture

The interface does not depend directly on SQLite, `yt-dlp`, `youtubedl-android`, or the audio engines. Communication flows through entities, use cases, repositories, providers, and interchangeable services.

```text
lib/
  core/
    constants/
    errors/
    platform/
    utils/
  features/music/
    domain/
      entities/
      repositories/
      usecases/
    data/
      datasources/
      models/
      repositories/
    presentation/
      pages/
      providers/
      widgets/
  platform_channels/
  services/
    downloader/
    live/
    lyrics/
    media_session/
    player/
    storage/
```

The main contracts are `DownloaderService`, `PlayerService`, `LyricsService`,
and `LibraryRepository`. Android uses platform channels for native tasks;
Windows and macOS execute local tools through argument lists and process their
output asynchronously.

## Development requirements

- Stable Flutter compatible with Dart `^3.12.0`.
- Android Studio and Android SDK for Android development.
- Visual Studio/Build Tools with **Desktop development with C++** for Windows.
- A stable Rust toolchain with the MSVC x64 target for Windows SMTC builds.
- Clang, CMake, Ninja, GTK 3, and libmpv for Linux.
- A Mac with Xcode to build, sign, and test macOS.
- Python 3.11–3.13 only when developing or rebuilding the TikTok bridge.
- `yt-dlp` and Deno 2.3 or newer for complete YouTube support on desktop.
  Node.js 22 or newer can be used as a development fallback.

Check the environment with:

```powershell
flutter doctor -v
flutter pub get
```

## Run the project

```powershell
flutter run -d windows
flutter run -d android
flutter run -d linux
flutter run -d macos
```

List available devices with:

```powershell
flutter devices
```

## Windows tools

Third-party binaries are **not committed to Git**. `yt-dlp` may be available on `PATH`. The recommended layout is:

```text
windows/tools/
  yt-dlp.exe
  deno.exe
  tiktok-live-bridge/
    tiktok_live_bridge.exe
    ...generated runtime...
```

Install `yt-dlp` with `winget`:

```powershell
winget install yt-dlp.yt-dlp
```

For a portable Windows build, place verified `yt-dlp` and Deno executables in
`windows/tools` before compiling Release. CMake copies both next to the
executable. During development, BStream can enable a compatible Node.js from
`PATH` when a bundled Deno executable is unavailable.

## macOS tools and permissions

Before compiling Release or Profile, place a verified native binary in:

```text
macos/tools/
  yt-dlp
  deno
```

`yt-dlp_macos` is also recognized. The **Bundle Desktop Tools** phase copies it under a stable name to:

```text
bstream_music.app/Contents/Resources/tools/
```

The copy phase sets executable permissions. A Release or Profile build fails
explicitly if `yt-dlp` or Deno is missing, preventing a package with incomplete
YouTube support. BStream prioritizes the bundled tools and keeps `PATH` as a
development fallback.

The application is distributed outside the Mac App Store. App Sandbox is disabled because BStream needs to launch `yt-dlp`, access the selected download folder, and make network connections. Hardened Runtime remains enabled for Developer ID signing and notarization. TikTok LIVE remains limited to Windows.

The native macOS window uses the same `960 × 600` minimum as Windows.

## Linux tools

Executables use this layout:

```text
linux/tools/
  yt-dlp
  deno
```

CMake copies both executables into `tools/` inside the bundle. The target system
must provide GTK 3, libmpv, and SQLite runtime libraries for the application
and its `media_kit` player.

## TikTok LIVE bridge

During development, BStream can run the bridge directly:

```text
scripts/tiktok_live_bridge.py
```

The application creates a virtual environment automatically when the packaged bridge is unavailable. You can also prepare it manually:

```powershell
py -3 -m venv .venv-tiktok
.\.venv-tiktok\Scripts\python.exe -m pip install -r scripts\requirements-tiktok.txt
```

Build the portable runtime used by a Windows Release build with:

```powershell
.\scripts\build_tiktok_bridge.ps1 -Jobs 28
```

The result is written to `windows/tools/tiktok-live-bridge/`. This directory contains Python, DLLs, and compiled dependencies, so it is excluded from Git and must be regenerated locally. The bridge watches the BStream process ID and exits when the application closes, preventing orphan processes and locked DLLs.

## Android

Native integration is located at:

```text
lib/platform_channels/android_ytdl_channel.dart
android/app/src/main/kotlin/com/bstream/bstream_music/MainActivity.kt
```

Main dependencies:

```kotlin
implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
```

`youtubedl-android` is downloaded through Gradle; manual executables are not committed to the repository.

Release builds intentionally support only the 64-bit `arm64-v8a` (ARMv8) and
`x86_64` ABIs. `armeabi-v7a` is no longer generated or supported.

### Release signing

Copy `android/key.properties.example` to `android/key.properties` and configure a key outside the repository:

```properties
storeFile=../release/bstream-upload-keystore.jks
storePassword=...
keyAlias=bstream
keyPassword=...
```

These environment variables are also supported:

```powershell
$env:BSTREAM_ANDROID_STORE_FILE="D:\keys\bstream-upload-keystore.jks"
$env:BSTREAM_ANDROID_STORE_PASSWORD="..."
$env:BSTREAM_ANDROID_KEY_ALIAS="bstream"
$env:BSTREAM_ANDROID_KEY_PASSWORD="..."
```

`android/key.properties`, `*.jks`, and `*.keystore` are excluded from Git.

GitHub Actions uses the same signing key through encrypted repository secrets:

```text
BSTREAM_ANDROID_KEYSTORE_BASE64
BSTREAM_ANDROID_STORE_PASSWORD
BSTREAM_ANDROID_KEY_ALIAS
BSTREAM_ANDROID_KEY_PASSWORD
```

The workflow verifies both APK signatures before uploading the artifacts.

## Database, favorites, and backups

- Android/macOS use `sqflite`; Windows and Linux use `sqflite_common_ffi`.
- Incremental migrations preserve existing libraries.
- Favorites are implemented as a reserved playlist (`bstream:favorites`), so no separate table is required.
- ZIP backups contain the database, `audio/`, `thumbnails/`, and a manifest.
- Restore validates file paths and archive limits before replacing local data.

## Generate icons

The source asset is `assets/icons/source/ico.png`. Regenerate all variants with:

```powershell
.\scripts\generate_app_icons.ps1
```

The script generates Android mipmaps, the Windows `.ico`, the macOS AppIcon, and Flutter resource variants.

## Build

```powershell
flutter build windows --release
flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64
flutter build linux --release
```

On a Mac, after preparing `macos/tools`:

```bash
flutter build macos --release
```

Typical artifacts:

```text
build/windows/x64/runner/Release/bstream_music.exe
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
build/app/outputs/flutter-apk/app-x86_64-release.apk
build/linux/x64/release/bundle/bstream_music
build/macos/Build/Products/Release/bstream_music.app
```

## Release packages with GitHub Actions

The `Release installers` workflow generates signed Android APKs and independent
Release installers for Windows, Linux, and both macOS architectures. It can be
run manually from the **Actions** tab and also runs for pull requests, pushes to
`main`, and `v*` tags.

Each desktop job downloads `yt-dlp` and Deno from their official releases and
verifies their pinned checksums. Windows also builds and verifies the portable
TikTok LIVE bridge runtime. Binaries are included in the installers but are not
stored in the repository. Artifacts are retained for 30 days:

```text
BStream-Music-1.2.1-Android-arm64-v8a.apk
BStream-Music-1.2.1-Android-x86_64.apk
BStream-Music-1.2.1-Windows-x64-Setup.exe
BStream-Music-1.2.1-linux-amd64.deb
BStream-Music-1.2.1-linux-x86_64.rpm
BStream-Music-1.2.1-macOS-arm64.pkg
BStream-Music-1.2.1-macOS-x64.pkg
```

### Which file should I install?

- **Most Android phones and tablets:** install `BStream-Music-1.2.2-Android-arm64-v8a.apk`.
- **Android x86_64 devices and emulators:** install `BStream-Music-1.2.2-Android-x86_64.apk`.
- **Windows 64-bit:** open `Setup.exe`. The installer shows a language selector, creates a Start Menu shortcut, and lets you choose whether to create a desktop shortcut. The uninstaller entry is displayed as `BStream Music` without the version number.
- **Ubuntu, Debian, Linux Mint, and derivatives:** install the `.deb` with `sudo apt install ./BStream-Music-1.2.2-linux-amd64.deb`.
- **Fedora, RHEL, and derivatives:** install the `.rpm` with `sudo dnf install ./BStream-Music-1.2.2-linux-x86_64.rpm`.
- **Mac with Apple Silicon (M1, M2, M3, M4, or later):** open `BStream-Music-1.2.2-macOS-arm64.pkg`.
- **Mac with an Intel processor:** open `BStream-Music-1.2.1-macOS-x64.pkg`.

An `.app` is the complete application and should be opened as one unit, not by entering its `Contents`, `Frameworks`, or `Resources` folders. The `.pkg` installer places `BStream Music.app` in `/Applications` automatically.

The automated installers are not signed with commercial certificates yet. Windows may show a SmartScreen warning and macOS may show a Gatekeeper warning. Public distribution without those warnings requires a Windows code-signing certificate and Apple Developer ID certificates with notarization.

The version is defined in `pubspec.yaml`, while the text shown inside the application is defined in `lib/core/constants/app_constants.dart`.

## Quality

```powershell
dart format .
flutter analyze
flutter test
```

The current test suite covers models, use cases, services, the sleep timer, TikTok permissions, navigation, favorites, queue behavior, mobile adaptation, and the Windows player at minimum size.

## Files not published

The repository deliberately excludes:

- Builds, APKs, EXEs, and distribution packages.
- `yt-dlp`, Deno, and their auxiliary directories.
- The compiled TikTok bridge runtime.
- Python virtual environments and caches.
- Signing keys, passwords, and local Android configuration files.
- Databases, downloaded music, thumbnails, and user backups.

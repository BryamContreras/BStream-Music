# BStream Music

BStream Music is a cross-platform music player and library manager built with Flutter. It lets you search for music, play and download tracks, organize a local library, and manage playlists on Android, Windows, Linux, and macOS.

Current version: **1.2.4+124**.

> The repository does not store media content or third-party binaries. Android
> and desktop builds download and bundle a checksum-verified `yt-dlp`; desktop
> installers also bundle Deno. Users are responsible for complying with
> copyright laws, provider terms, and the licenses of these tools.

<img width="1221" height="840" alt="{3AC80665-A6EC-436D-9C87-A1413432F0E3}" src="https://github.com/user-attachments/assets/8c918bae-6f84-46fa-8923-24ea68b6f8a4" />

## What's new in 1.2.4

- Resolve and download YouTube audio with `youtube_explode_dart` first, validate
  the exact selected stream, and fall back visibly to yt-dlp only when needed.
- Search YouTube Music through InnerTube tabs for Songs, Videos, and Albums;
  switch categories with an accessible cross-fade, and open albums, mixes, and
  playlists in bounded, contrast-safe blurred artwork detail pages before
  creating their queues.
- Show refreshable YouTube Music shelves on Home while hiding empty local
  Recently played and Playlists sections, and preserve engine-detected
  duration and seeking when recommendation metadata omits the track length.
- Import and export library metadata through robust CSV profiles compatible
  with BStream, MetroList, Harmony/RiMusic, Soundiiz, and common layouts.
- Run TikTok LIVE queues natively in Dart on Android, Windows, Linux, and macOS,
  with optional saving to the Library and bounded request processing.
- Use generation-aware, time-bounded playback opens and latest-request-wins
  managed fallback downloads so stale sources cannot block a new song or Stop.
- Preserve native M4A/AAC, WebM/Opus, and other supported YouTube audio formats,
  with bounded temporary caches and validated partial downloads.
- Improve Settings navigation, compact card styling, language selection,
  transfer actions, lyrics animation choices, and persistent appearance options.
- Improve small-device and accessibility behavior with lazy library lists,
  bounded artwork decoding, 48 dp controls, and layouts tested at 300% text.
- Include release APKs for ARMv7, ARMv8, and x86_64, and remove the obsolete
  external Python TikTok LIVE bridge from desktop packages.
- Share a YouTube-backed song with a BStream Music link that opens the player
  on Android, Windows, Linux, or macOS, while retaining a YouTube fallback.

## Main features

### Search, downloads, and library

- InnerTube search tabs for Songs, Videos, and Albums, with up to 20 results,
  artwork, metadata, and album queues loaded only when selected.
- If InnerTube fails, yt-dlp keeps discovery available as generic YouTube
  Videos without mislabeling them as Songs or Albums.
- Search text remains available between searches and has an inline clear action.
- Remote song rows in Search and album, playlist, and mix details provide a
  dedicated Play/Pause control and a More menu for Download and Add to
  playlist; tapping the row still opens the full player.
- Remote playback and audio downloads with real-time progress.
- Direct YouTube playback falls back to a short-lived, chunked yt-dlp cache
  when GoogleVideo rejects the player's HTTP range requests; native M4A/AAC,
  WebM/Opus, and other available audio containers remain unconverted. Stale
  A -> B -> C preparations are cancelled, stalled transfers time out, and the
  managed fallback cache is bounded to 12 files (128 MiB total/64 MiB per file
  on Android; 256 MiB total/128 MiB per file on desktop).
- High-quality artwork uses one proportional crop policy from search through
  playback and downloaded-library storage.
- SQLite-backed local library.
- Reuse of downloaded tracks to avoid duplicate downloads.
- Filtering, renaming, and deletion of saved tracks.
- Playlist creation, renaming, and deletion.
- Playlist and downloaded-song headers show both song count and total duration.
- Dedicated **Favorites** playlist with accent-colored hearts on favorited
  tracks.
- ZIP backup and restore for the database, audio files, and thumbnails.
- CSV import/export for BStream, MetroList, Harmony/RiMusic, Soundiiz,
  Exportify, and common title/artist/album/ISRC layouts. CSV imports show a
  preview, reuse existing local tracks, and download missing songs one at a
  time only after confirmation; CSV exports contain metadata, not audio.

### Player

- Play, pause, previous, next, repeat, and shuffle controls.
- Mobile Lyrics and Volume controls use labeled buttons beneath Shuffle and
  Repeat, while an accent-colored heart beside the title toggles Favorites on
  every platform.
- The Share button beside Favorites sends both a compact
  `bstreammusic://track/<videoId>` app link and the canonical YouTube watch
  URL. Installed packages on Android, Windows, Linux, and macOS register the
  BStream scheme; the YouTube URL remains available when that scheme cannot be
  opened. Local-only files without a YouTube identity are intentionally not
  shared.
- Lyrics offer four persistent animation styles, Normal/Centered alignment,
  and a live preview in Appearance settings.
- Playback queue synchronized with playlists and the library.
- Queue side panel on Windows and a dedicated queue view on Android.
- Change tracks directly from the queue and reorder them with a long press.
- Android keeps a rolling native queue for remote playback, with up to three
  upcoming tracks prepared sequentially so locked-screen transitions do not
  depend on reopening the app. The bounded disk window prioritizes the current
  track, those three upcoming tracks, and the previous track; interrupted-
  session leftovers expire after 30 minutes.
- On Android, Quick picks that omit catalog duration adopt ExoPlayer's detected
  duration after loading, keeping the timeline and seeking available.
- Desktop also prepares up to three upcoming remote tracks as complete local
  files. Its 12-hour LRU cache keeps at most 24 files, 256 MiB total, and
  128 MiB per track; changing queues or stopping playback releases protection
  without discarding reusable audio. Minimizing or locking the PC keeps the
  player running, while closing the application exits playback.
- The active track is highlighted with a segmented 13-bar equalizer.
- Theme-aware dynamic background derived from the track artwork.
- Animated progress bar with waves and the selected accent color.
- Direct volume control beside the repeat button.
- Synchronized lyrics powered by LRCLIB, with plain-lyrics fallback, automatic
  scrolling, tap-to-seek, and a manual timing offset from `-10` to `+10` seconds
  in `0.50`-second steps.
- Sleep timer with quick durations and a custom duration.
- Native system media integration: Android media notifications, Windows
  SMTC, Linux MPRIS, and macOS Now Playing.
- Source opens use bounded deadlines and generation/epoch isolation. A broken
  decoder or network source cannot hold a newer selection, Stop, or shutdown
  indefinitely, and late events from the retired source are ignored.
- Windows registers a stable application identity so SMTC shows the BStream
  Music name and icon in system media controls.
- Failed-track handling: a track that cannot be downloaded or played does not leave the queue stuck on the previous track.

### Interface

- Responsive mobile and desktop layouts with bounded artwork decoding,
  lazy library lists, 48 dp touch targets, and large-text adaptation.
- System, Light, and Dark themes with eighteen persistent accent palettes.
- Navigation remembers only the two most recent views.
- Returning from the player restores the previously opened playlist or section.
- Home displays up to 10 recently played items and 10 playlists. Recent items
  restore their last valid source playlist and fall back safely when that
  playlist no longer exists.
- Subtle gradients, translucent cards, and shared visual controls.
- Spanish and English selectable from Settings.
- Optional Ko-fi development support link below the app version in Settings;
  BStream Music remains free.
- Windows window minimum size of `960 × 600`; the player progressively adapts artwork, text, spacing, and controls to the available height.
- Icons generated from one source asset for Android, Windows, macOS, and Flutter resources.

## TikTok LIVE on Android, Windows, Linux, and macOS

Every supported BStream platform connects to TikTok LIVE through a client
implemented directly in Dart and turns chat commands into a temporary music
queue. The integration does not launch an external bridge.

Available features:

- Connect using `@username` or `https://www.tiktok.com/@username/live`.
- Detect the user who requested each track.
- Identify moderators.
- Configure command permissions for **Everyone** or **Moderators only**.
- LIVE queue states for searching, downloading, ready, and failed requests.
- A bounded 50-request queue that rejects additional commands explicitly
  instead of allowing an unbounded search/download backlog.
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

On Android, the connection can continue while the app is normally in the
background as long as its Flutter process remains alive. Force-stopping the app
or Android reclaiming that process also ends the LIVE connection; it is not an
independent background service.

This integration uses an unofficial, reverse-engineered protocol. If TikTok
changes it, the Dart client may need to be updated. BStream Music is not
affiliated with or endorsed by TikTok or ByteDance.

## Platforms and engines

| Platform | Player | Downloads | Notes |
| --- | --- | --- | --- |
| Android | `just_audio` + `audio_service` | `youtubedl-android` + QuickJS | `minSdk 24`; TikTok LIVE; open local audio from Android; release APKs support `armeabi-v7a`, `arm64-v8a`, and `x86_64` |
| Windows | `media_kit` | Bundled `yt-dlp` + Deno | SMTC controls, TikTok LIVE, queue side panel, and external tools |
| Linux | `media_kit` | Bundled `yt-dlp` + Deno | MPRIS controls; TikTok LIVE; Ubuntu 22.04-based x64 installers; requires GTK 3, libmpv, and SQLite |
| macOS | `media_kit` | Bundled `yt-dlp` + Deno | Now Playing controls; TikTok LIVE; separate PKG installers for Apple Silicon and Intel; minimum window `960 × 600` |

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
15-minute in-memory cache of at most 24 songs to avoid duplicate requests.
Lyrics are not embedded in downloaded audio files, and this cache disappears
when the app process closes.

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

The application is distributed outside the Mac App Store. App Sandbox is disabled because BStream needs to launch `yt-dlp`, access the selected download folder, and make network connections. Hardened Runtime remains enabled for Developer ID signing and notarization. TikTok LIVE uses the same in-process Dart transport on macOS as on Android, Windows, and Linux.

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

## TikTok LIVE client

TikTok LIVE networking, reconnection, Protobuf decoding, command parsing, and
WebSocket keepalive handling run inside the Dart application. Builds do not
bundle or start a companion runtime for this integration.

The transport uses an audited in-tree fork of the 0BSD-licensed
`piratetok_live` 0.1.5 project. See
[Third-party notices](THIRD_PARTY_NOTICES.md) for attribution.

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

`youtubedl-android` is downloaded through Gradle. Its wrapper and embedded
Python/QuickJS runtime are kept at `0.18.1`, while the app build downloads the
pinned official `yt-dlp` zipapp, verifies its SHA-256 checksum, and overlays the
older extractor resource shipped by the wrapper. The verified file is cached
under the Gradle user directory and is not committed to the repository.

The current Android bundle uses stable yt-dlp `2026.07.04`. When an installed
APK is upgraded, BStream migrates an older extracted copy to the bundled
version but preserves an updater-downloaded copy when it is the same version or
newer. Recoverable extractor failures can still trigger one stable-channel
update and retry at runtime.

Release builds support the 32-bit `armeabi-v7a` (ARMv7), 64-bit `arm64-v8a`
(ARMv8), and emulator/device `x86_64` ABIs. All require Android 7.0 or newer
through the shared `minSdk 24` baseline.

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

The workflow verifies all three APK signatures before uploading the artifacts.

## Database, favorites, and backups

- Android/macOS use `sqflite`; Windows and Linux use `sqflite_common_ffi`.
- Incremental migrations preserve existing libraries.
- Favorites are implemented as a reserved playlist (`bstream:favorites`), so no separate table is required.
- ZIP backups contain the database, `audio/`, `thumbnails/`, and a manifest.
- The Storage page separates local ZIP backup transfer from portable CSV
  transfer. BStream CSV preserves playlist membership and order; compatibility
  profiles can be selected when exporting to other music-library apps.
- Restore validates the manifest, archive paths and limits, SQLite integrity,
  schema, and version before touching local data. Database and media changes
  are staged on their destination filesystems and rolled back if activation
  fails.

## Generate icons

The source asset is `assets/icons/source/ico.png`. Regenerate all variants with:

```powershell
.\scripts\generate_app_icons.ps1
```

The script generates Android mipmaps, the Windows `.ico`, the macOS AppIcon, and Flutter resource variants.

## Build

```powershell
flutter build windows --release
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64,android-x64
flutter build linux --release
```

On a Mac, after preparing `macos/tools`:

```bash
flutter build macos --release
```

Typical artifacts:

```text
build/windows/x64/runner/Release/bstream_music.exe
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
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

Android and desktop jobs download `yt-dlp` from its official release and verify
the pinned checksum. The Android job additionally opens all three completed
APKs and checks each ABI plus the embedded extractor's hash and reported
version. Desktop jobs also
bundle Deno. The TikTok LIVE client is part of the Dart application and needs
no additional runtime. Binaries are included in the installers but are not
stored in the repository. Artifacts are retained for 30 days:

```text
BStream-Music-<version>-Android-armeabi-v7a.apk
BStream-Music-<version>-Android-arm64-v8a.apk
BStream-Music-<version>-Android-x86_64.apk
BStream-Music-<version>-Windows-x64-Setup.exe
BStream-Music-<version>-linux-amd64.deb
BStream-Music-<version>-linux-x86_64.rpm
BStream-Music-<version>-macOS-arm64.pkg
BStream-Music-<version>-macOS-x64.pkg
```

### Which file should I install?

- **Most Android phones and tablets:** install `BStream-Music-<version>-Android-arm64-v8a.apk`.
- **Older 32-bit ARM Android devices:** install `BStream-Music-<version>-Android-armeabi-v7a.apk`.
- **Android x86_64 devices and emulators:** install `BStream-Music-<version>-Android-x86_64.apk`.
- **Windows 64-bit:** open `Setup.exe`. The installer shows a language selector, creates a Start Menu shortcut, and lets you choose whether to create a desktop shortcut. The uninstaller entry is displayed as `BStream Music` without the version number.
- **Ubuntu, Debian, Linux Mint, and derivatives:** install the `.deb` with `sudo apt install ./BStream-Music-<version>-linux-amd64.deb`.
- **Fedora, RHEL, and derivatives:** install the `.rpm` with `sudo dnf install ./BStream-Music-<version>-linux-x86_64.rpm`.
- **Mac with Apple Silicon (M1, M2, M3, M4, or later):** open `BStream-Music-<version>-macOS-arm64.pkg`.
- **Mac with an Intel processor:** open `BStream-Music-<version>-macOS-x64.pkg`.

An `.app` is the complete application and should be opened as one unit, not by entering its `Contents`, `Frameworks`, or `Resources` folders. The `.pkg` installer places `BStream Music.app` in `/Applications` automatically.

The automated installers are not signed with commercial certificates yet. Windows may show a SmartScreen warning and macOS may show a Gatekeeper warning. Public distribution without those warnings requires a Windows code-signing certificate and Apple Developer ID certificates with notarization.

The version is defined in `pubspec.yaml`, while the text shown inside the application is defined in `lib/core/constants/app_constants.dart`.

## Quality

```powershell
dart format .
flutter analyze
flutter test
```

The current test suite covers models, use cases, services, the sleep timer,
TikTok permissions, navigation, favorites, queue behavior and reordering,
external Android audio, themes, artwork handling, backup validation, mobile
adaptation, and the Windows player at minimum size.

The release workflow runs formatting, static analysis, and the complete test
suite before any installer job. Pull-request runs are cancelled when a newer
commit supersedes them.

## Files not published

The repository deliberately excludes:

- Builds, APKs, EXEs, and distribution packages.
- `yt-dlp`, Deno, and their auxiliary directories.
- Signing keys, passwords, and local Android configuration files.
- Databases, downloaded music, thumbnails, and user backups.

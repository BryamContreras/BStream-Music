# BStream Music

BStream Music is a cross-platform music player and library manager built with Flutter. It lets you search for music, play and download tracks, organize a local library, and manage playlists on Android, iOS, Windows, Linux, and macOS.

Current version: **1.2.6+126**.

> The repository does not store media content. YouTube search, playback, and
> downloads use BStream's self-contained Dart InnerTube pipeline. Supported
> builds neither bundle nor launch an external media resolver. Users are
> responsible for complying with copyright laws and provider terms.

<img width="1221" height="840" alt="{3AC80665-A6EC-436D-9C87-A1413432F0E3}" src="https://github.com/user-attachments/assets/8c918bae-6f84-46fa-8923-24ea68b6f8a4" />

## What's new in 1.2.6

- Run BStream on iOS 13 or newer with embedded account login, background audio
  and Now Playing controls, native access to downloaded non-DRM Media Library
  songs, TikTok LIVE, and document-picker backup and CSV export. CI also
  publishes `BStream-Music-<version>-iOS-unsigned.ipa` for testing through a
  compatible external signing or sideloading tool.
- Use in-process Dart InnerTube services for catalog search, playback, and
  downloads on every platform. Playback and downloads share the same maintained
  client ladder and require no vendored extractor library, native extraction
  runtime, or companion resolver executable.

- Sign in to YouTube Music from an isolated account view without BStream
  intercepting or storing the Google password. Session data is encrypted on
  the device, the first playlist sync requires a separate confirmation, and
  the Home avatar exposes channel selection, sync, conflicts, and logout.
- Synchronize local and YouTube Music playlists by stable identities with a
  conservative three-way merge. Local playlists are retained, remote copies
  are private by default, and BStream Favorites is synchronized with YouTube
  Music's **Liked Music** collection. Remote deletion always requires a
  separate explicit confirmation.
- Keep streaming-only songs and duplicate occurrences inside imported
  playlists. Playback uses a valid downloaded file first and falls back to the
  matching stream.
- Learn account-free Home recommendations from qualified local playback
  history using YouTube Music `/next`, related shelves, mixes, and exact artist
  releases. History can be disabled or cleared without removing the library.
- Retry an interrupted active stream through the InnerTube client ladder with
  bounded backoff, while recommendation queues grow as their
  end approaches and stale navigation work is cancelled.
- Split the former 3,600-line player controller into focused queue, retry,
  prefetch, crossfade, identity, and history coordinators. Database v8 adds the
  hybrid playlist catalog, bounded history retention, and crash-safe media
  migration.
- Open the full player safely from a notification or launcher entry: Back now
  returns to Home even when no previous in-app destination exists, while Queue
  still consumes its own Back action first.
- Mount the interface before optional native startup services, retry only a
  failed service, harden backup/restore budgets and schema checks, and verify
  Android release APKs exclude obsolete external resolver runtimes.
- Resolve YouTube manifests directly through a maintained Dart InnerTube
  client ladder, with EJS challenge solving and optional Web BotGuard PO-token
  generation when a client requires them.
- Download native YouTube audio through the same InnerTube resolver, with
  exact-stream validation, client fallbacks, bounded deadlines, resumable
  transfers, and safe partial-file publication.
- Crossfade playback now uses two coordinated decks on Android and desktop and
  can be adjusted to every whole second from 1 to 15 in Playback settings.
- Romanize lyrics while retaining the original line above a smaller
  transliteration. Japanese, Korean, Chinese, Cyrillic, Arabic, and Hebrew can
  be enabled independently, and the live appearance preview shows the result.
- Restore CSV libraries with up to three bounded concurrent resolutions and
  downloads while preserving playlist order, deduplication, cancellation, and
  per-track failure reporting.
- Refine the full and mini players across compact Android screens and desktop,
  including clearer transport controls, denser timelines, safer CJK metadata,
  and an independent accent-tinted desktop mini-player surface.
- Toggle desktop playback with Space from either player without intercepting
  typing in Search or another editable field.
- Use consistent compact cards and larger artwork across Library and Settings,
  a wider desktop playback queue, and smoother Search and navigation changes.
- Remove the obsolete no-animation lyrics option and default legacy preferences
  safely to Smooth. On mobile, Lyrics uses its artwork as Back, provides a
  larger Play/Pause action in the header, and does not duplicate the mini-player.

## Main features

### Search, downloads, and library

- Optional YouTube Music account sign-in and bidirectional playlist sync. New
  local playlists are created remotely as private playlists, imported remote
  playlists may contain streaming-only entries, and BStream Favorites maps to
  YouTube Music's **Liked Music** collection. The system playlist “Episodes for
  later” is intentionally excluded.
- Synced playlist playback is download-first: BStream uses a valid local copy
  when available and falls back to streaming the same catalog entry when the
  file is missing or cannot be opened.
- InnerTube search tabs for Songs, Videos, and Albums, with up to 20 results,
  artwork, metadata, and album queues loaded only when selected.
- InnerTube discovery keeps Songs, Videos, Albums, artists, and releases on the
  same Dart transport used by playback.
- Search text remains available between searches and has an inline clear action.
- Remote song rows in Search and album, playlist, and mix details provide a
  dedicated Play/Pause control and a More menu for Download and Add to
  playlist; tapping the row still opens the full player.
- Remote playback and audio downloads with real-time progress.
- Direct YouTube playback and downloads use a maintained, deterministic Dart
  InnerTube client ladder with page-specific dynamic bootstrap. Solver-dependent
  retries use pinned EJS modules in a headless JavaScript runtime and generate
  Web BotGuard PO tokens only for profiles that require them; degraded fallback
  tokens fail closed and independent EJS/WebPO capability circuit breakers
  advance immediately to tokenless clients. If an active stream loses
  connectivity, BStream
  retries the resolver chain with bounded backoff; navigation cancels obsolete
  attempts. Every selected candidate is deep-probed at or beyond 3 MiB before
  publication, and downloads resume through validated range requests and safe
  `.part` files. Native M4A/AAC, WebM/Opus, and other available audio
  containers remain unconverted; when YouTube exposes only a direct muxed
  fallback, it is preserved as `.mp4` instead of being mislabeled or
  transcoded.
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
- CSV imports recognize BStream, MetroList, Harmony/RiMusic, Soundiiz,
  Exportify, and common title/artist/album/ISRC layouts. They show a preview,
  reuse existing local tracks, and process up to three missing songs
  concurrently only after confirmation while retaining source playlist order.
  Exports offer BStream Music, MetroList, Harmony/RiMusic, and Soundiiz profiles
  and contain metadata, not audio.

### Player

- Play, pause, previous, next, repeat, and shuffle controls.
- Mobile Lyrics and Volume controls use labeled buttons beneath Shuffle and
  Repeat, while an accent-colored heart beside the title toggles Favorites on
  every platform.
- The Share button beside Favorites sends one canonical HTTPS URL that chat
  applications can recognize: YouTube Music when the track came from the
  InnerTube catalog, otherwise the regular YouTube watch URL. Local-only files
  without a YouTube identity are intentionally not shared.
- Android can also offer BStream when opening public YouTube/YouTube Music
  links. Video links open the player directly; playlist and album links open a
  catalog view with Play and Add to playlist actions. Unsupported or unsafe
  URLs are ignored.
- Lyrics offer three persistent animation styles (Smooth by default),
  Normal/Centered alignment, optional per-script romanization, and a live
  preview in Appearance settings.
- Crossfade uses coordinated playback decks and supports every whole-second
  duration from 1 through 15 seconds on Android and desktop.
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
- On desktop, Space toggles Play/Pause from the mini or full player unless an
  editable text field such as Search currently has focus.
- Synchronized lyrics powered by LRCLIB, with plain-lyrics fallback, automatic
  scrolling, tap-to-seek, and a manual timing offset from `-10` to `+10` seconds
  in `0.50`-second steps.
- Sleep timer with quick durations and a custom duration.
- Native system media integration: Android media notifications, iOS and macOS
  Now Playing, Windows SMTC, and Linux MPRIS.
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
- Without requiring an account, Home learns only from qualified local playback
  events and combines YouTube Music related candidates with BStream's own
  ranking. Personalized shelves include **Because you listened**, **Your
  mixes**, **New for you**, and **Discovery for you**; the previous feed is
  shown instantly while a fresh one is prepared in the background.
- Recommendation learning can be paused or its local history and caches can be
  cleared from Privacy settings without removing downloads, favorites, or
  playlists.
- Subtle gradients, translucent cards, and shared visual controls.
- Spanish and English selectable from Settings.
- An Application information section in Settings opens an organized About the
  app detail with the current version, optional Ko-fi development support, and
  the official GitHub repository; BStream Music remains free.
- Windows window minimum size of `960 × 600`; the player progressively adapts artwork, text, spacing, and controls to the available height.
- Icons generated from one source asset for Android, iOS, Windows, macOS, and
  Flutter resources.

## TikTok LIVE on Android, iOS, Windows, Linux, and macOS

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
- Up to three requests are resolved concurrently, while completed tracks are
  committed to playback in the same order in which their commands arrived.
- A 30-second search deadline lets later requests continue past a stalled
  lookup; an active library download is allowed to finish normally.
- Command-first chat filtering and early WebSocket acknowledgements avoid
  building full viewer profiles for ordinary comments in busy rooms.
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

`!play` searches for the first result, prepares it, and adds it to the queue.
`!skip`/`!next` advance playback. `!revoke`/`revoke!` remove the last request
from the LIVE queue, while `!stop` pauses the current LIVE song.

On Android, the connection can continue while the app is normally in the
background as long as its Flutter process remains alive. Force-stopping the app
or Android reclaiming that process also ends the LIVE connection; it is not an
independent background service.

This integration uses an unofficial, reverse-engineered protocol. If TikTok
changes it, the Dart client may need to be updated. BStream Music is not
affiliated with or endorsed by TikTok or ByteDance. BStream can keep its local
processing responsive, but it can only act on chat messages that TikTok
actually delivers to the WebSocket client.

## Platforms and engines

| Platform | Player | Downloads | Notes |
| --- | --- | --- | --- |
| Android | `just_audio` + `audio_service` | Dart InnerTube | `minSdk 24`; optional headless WebView for EJS and Web BotGuard PO tokens; TikTok LIVE; open local audio from Android; release APKs support `armeabi-v7a`, `arm64-v8a`, and `x86_64` |
| iOS | `just_audio` + `audio_service` | Dart InnerTube | iOS 13 or newer; embedded account login and optional headless WebView challenges; background audio and Now Playing; TikTok LIVE; native access to locally available, non-DRM songs in the Media Library; CI publishes an unsigned IPA for use with a compatible external signing tool |
| Windows | `media_kit` | Dart InnerTube | Optional headless WebView for EJS and Web BotGuard PO tokens; SMTC controls, TikTok LIVE, and queue side panel |
| Linux | `media_kit` | Dart InnerTube | Three tokenless/JS-less InnerTube identities (`visionOS`, `androidSdkless`, `visionOS01`); MPRIS controls; TikTok LIVE; Ubuntu 22.04-based x64 installers; requires GTK 3, libmpv, SQLite, and libsecret |
| macOS | `media_kit` | Dart InnerTube | Optional headless WebView for EJS and Web BotGuard PO tokens; Now Playing controls, TikTok LIVE, separate PKG installers for Apple Silicon and Intel; minimum window `960 × 600` |

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

The interface is isolated from SQLite, the media engines, and provider
protocol details. Communication flows through entities, use cases,
repositories, providers, and interchangeable services. The remote catalog,
playback, and download stack is implemented directly in Dart without a
vendored extractor library or companion resolver runtime.

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
    youtube_music/
      playback/
    live/
    lyrics/
    media_session/
    player/
    storage/
third_party/
  piratetok_live/
```

The main contracts are `DownloaderService`, `AudioStreamResolver`,
`PlayerService`, `LyricsService`, and `LibraryRepository`. The
InnerTube playback implementation is isolated under
`lib/services/youtube_music/playback/`; downloader and resolver adapters expose
it through the app contracts without leaking protocol types. Android uses
platform channels for unrelated native tasks; YouTube resolution and transfer
remain inside the Dart service layer on every platform.

## Development requirements

- Stable Flutter compatible with Dart `^3.12.0`.
- Android Studio and Android SDK for Android development.
- Visual Studio/Build Tools with **Desktop development with C++** for Windows.
- The pinned NuGet CLI on `PATH` for Windows plugin dependencies (the build
  bootstrap below installs it when needed).
- A stable Rust toolchain with the MSVC x64 target for Windows SMTC builds.
- Clang, CMake, Ninja, GTK 3, libmpv, SQLite, and libsecret for Linux.
- A Mac with Xcode and CocoaPods to build and test iOS or macOS. Creating the
  unsigned iOS application and IPA needs no Apple certificate; direct device,
  TestFlight, and App Store installation still require an accepted signature
  and provisioning method.

Check the environment with:

```powershell
flutter doctor -v
flutter pub get
```

## Run the project

```powershell
flutter run -d windows
flutter run -d android
flutter run -d <ios-device-id>
flutter run -d linux
flutter run -d macos
```

List available devices with:

```powershell
flutter devices
```

## Windows build dependencies

The Windows WebView login needs the NuGet CLI at build time. The project now
bootstraps the pinned, checksum-verified CLI automatically during CMake
configuration, so the normal command is enough:

```powershell
flutter clean
flutter pub get --enforce-lockfile
flutter build windows --release
```

If an older generated build still reports `NUGET-NOTFOUND`, delete
`build/windows` once and rerun `flutter run -d windows`; CMake will install the
same pinned tool automatically. The bootstrap also works around the hidden
`AppData` path bug in `smtc_windows` 1.1.0, which otherwise appears as a
misleading `Get-Item C:\\Users\\...\\AppData` error.

The script downloads NuGet `6.12.2` from the official distribution endpoint,
verifies its SHA-256, and stores it under the user/runner tool directory. A
WebView2 Runtime is required to run the login screen on the Windows machine;
it is not required merely to compile the application.

Windows Release builds need no YouTube resolver executable. Playback,
downloads, EJS challenge handling, and optional Web PO-token generation are
provided by the Dart application and its headless WebView runtime.

## iOS support

The iOS runner targets iOS 13 or newer. It registers the `bstreammusic` custom
URL scheme, keeps account credentials in the system Keychain, and enables the
audio background mode for lock-screen and Now Playing controls. Remote search,
playback, downloads, embedded YouTube Music account login, TikTok LIVE, backup
export, and CSV export are adapted to iOS. The system document picker handles
exports outside BStream's sandbox.

With the user's Media Library permission, the Local view reads songs through
`MPMediaLibrary`. Only media that is downloaded to the device, exposes a
playable asset URL, and is not DRM-protected is listed. Cloud-only Apple Music
items remain unavailable until iOS downloads them locally. BStream's downloaded
tracks remain in its own library as on the other platforms.

The app cannot claim public `youtube.com` links as Universal Links because
those domains do not publish an association for BStream; app-owned
`bstreammusic://` links remain supported.

The repository's CI compiles both an unsigned simulator application and an
unsigned Release application for physical devices. It packages the latter as
`BStream-Music-<version>-iOS-unsigned.ipa` and uploads it to the corresponding
GitHub Actions run; it does not sign the package or publish it to a store.

The unsigned IPA can be used as input for an external signing or sideloading
tool such as GBox. It is not directly installable in its unsigned state: the
chosen tool must sign or re-sign it using credentials and provisioning that the
target device accepts. GBox and similar services are independent of BStream,
and their availability and compatibility are not guaranteed by this project.

Media Library behavior must be tested on a physical device because it is not
available in the simulator. Xcode device deployment, TestFlight, and App Store
distribution require the corresponding Apple signing and provisioning setup.

## macOS permissions

The application is distributed outside the Mac App Store. App Sandbox is
disabled so BStream can access the selected download folder and make network
connections. Hardened Runtime remains enabled for Developer ID signing and
notarization. Release bundles contain no external YouTube resolver or
JavaScript runtime. TikTok LIVE uses the same in-process Dart transport on
macOS as on Android, Windows, and Linux.

The native macOS window uses the same `960 × 600` minimum as Windows.

## Linux runtime dependencies

Linux bundles contain no external YouTube resolver or JavaScript runtime. The
target system must provide GTK 3, libmpv, SQLite, and libsecret runtime
libraries for the application, secure storage, and its `media_kit` player. The
DEB and RPM declare these dependencies so the package manager installs them.

## TikTok LIVE client

TikTok LIVE networking, reconnection, Protobuf decoding, command parsing, and
WebSocket keepalive handling run inside the Dart application. Builds do not
bundle or start a companion runtime for this integration.

The transport uses an audited in-tree fork of the 0BSD-licensed
`piratetok_live` 0.1.5 project. See
[Third-party notices](THIRD_PARTY_NOTICES.md) for attribution.

## Android

YouTube stream resolution and downloads stay in the Dart service layer:

```text
lib/services/youtube_music/playback/
lib/services/downloader/innertube_audio_resolver.dart
lib/services/downloader/innertube_download_service.dart
lib/services/downloader/http_audio_transfer.dart
assets/youtube/po_token.html
```

The playback service routes requests through a maintained InnerTube client
ladder, bootstraps matching page/client context, validates stream ranges, and
falls back between client profiles when a request is rejected. Pinned EJS
modules solve player challenges through the headless WebView runtime, while
Web BotGuard PO tokens are generated only for profiles that require them and
never substitute an unbound fallback token. Downloads reuse the same resolved
streams and a resumable `dart:io` transfer. Android carries no external
resolver executable or embedded resolver runtime.

The remaining app-specific native Android integration is limited to platform
features that Flutter cannot provide directly:

```text
android/app/src/main/kotlin/com/bstream/bstream_music/MainActivity.kt
android/app/src/main/kotlin/com/bstream/bstream_music/ExternalAudioIntentHandler.kt
android/app/src/main/kotlin/com/bstream/bstream_music/LauncherActivity.kt
```

Those classes handle audio-service activity integration, file export, supported
links, screen flags, notification and media permissions, local/external audio
intents, artwork loading, and launcher transitions. There is no native
YouTube-resolver MethodChannel.

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

- Android, iOS, and macOS use `sqflite`; Windows and Linux use
  `sqflite_common_ffi`.
- Incremental migrations preserve existing libraries.
- Favorites are implemented as a reserved local playlist (`bstream:favorites`),
  so no separate table is required. After account consent, it is bound to
  YouTube Music's special **Liked Music** collection (LM/VLLM): likes and
  unlikes use the same conservative playlist sync engine, without importing a
  duplicate playlist. “Episodes for later” is ignored during account bootstrap.
- ZIP backups contain the database, `audio/`, `thumbnails/`, and a manifest.
- The Storage page separates local ZIP backup transfer from portable CSV
  transfer. BStream CSV preserves playlist membership and order; importing can
  resolve up to three missing tracks concurrently, and BStream Music,
  MetroList, Harmony/RiMusic, or Soundiiz can be selected as export profiles.
- Restore validates the manifest, archive paths and limits, SQLite integrity,
  schema, and version before touching local data. Database and media changes
  are staged on their destination filesystems and rolled back if activation
  fails.

## Generate icons

The source asset is `assets/icons/source/ico.png`. Regenerate all variants with:

```powershell
.\scripts\generate_app_icons.ps1
```

The script generates Android mipmaps, opaque iOS AppIcon assets, the Windows
`.ico`, the macOS AppIcon, and Flutter resource variants.

## Build

```powershell
flutter build windows --release
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64,android-x64
flutter build linux --release
```

On a Mac:

```bash
flutter build macos --release
flutter build ios --simulator --no-codesign
flutter build ios --release --no-codesign
```

The first iOS command produces a simulator application; the second produces the
unsigned device `Runner.app` that CI places inside the standard IPA `Payload/`
layout. After configuring an Apple development team and App Store provisioning,
a maintainer can instead create a signed archive locally with
`flutter build ipa --release`.

Typical artifacts:

```text
build/windows/x64/runner/Release/bstream_music.exe
build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
build/app/outputs/flutter-apk/app-x86_64-release.apk
build/linux/x64/release/bundle/bstream_music
build/macos/Build/Products/Release/bstream_music.app
build/ios/iphonesimulator/Runner.app
build/ios/iphoneos/Runner.app
dist/BStream-Music-<version>-iOS-unsigned.ipa
```

## Release packages with GitHub Actions

The `Release installers` workflow generates signed Android APKs and independent
Release installers for Windows, Linux, and both macOS architectures. Its iOS
job analyzes the project, runs the focused platform tests, compiles unsigned
simulator and device applications, packages the device application as an
unsigned IPA, verifies its structure, and uploads it as a GitHub Actions
artifact. The workflow can be run manually from the **Actions** tab and also
runs for pull requests, pushes to `main`, and `v*` tags.

Desktop jobs build and verify installers without downloading or bundling an
external YouTube resolver. The TikTok LIVE client is also part of the Dart
application and needs no additional runtime. Artifacts are retained for 30
days:

```text
BStream-Music-<version>-Android-armeabi-v7a.apk
BStream-Music-<version>-Android-arm64-v8a.apk
BStream-Music-<version>-Android-x86_64.apk
BStream-Music-<version>-Windows-x64-Setup.exe
BStream-Music-<version>-linux-amd64.deb
BStream-Music-<version>-linux-x86_64.rpm
BStream-Music-<version>-macOS-arm64.pkg
BStream-Music-<version>-macOS-x64.pkg
BStream-Music-<version>-iOS-unsigned.ipa
```

### Which file should I install?

- **Most Android phones and tablets:** install `BStream-Music-<version>-Android-arm64-v8a.apk`.
- **Older 32-bit ARM Android devices:** install `BStream-Music-<version>-Android-armeabi-v7a.apk`.
- **Android x86_64 devices and emulators:** install `BStream-Music-<version>-Android-x86_64.apk`.
- **iPhone and iPad:** download
  `BStream-Music-<version>-iOS-unsigned.ipa` from the artifacts of a successful
  **Release installers** run in GitHub Actions, then supply it to GBox or
  another compatible signing/sideloading tool. The IPA is deliberately
  unsigned and cannot be installed directly without being signed or re-signed
  by that tool. For Apple's supported development path, run it from Xcode or
  Flutter on a Mac with a development team configured.
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
external Android audio, iOS platform/login/local-media/export routing, themes,
artwork handling, backup validation, mobile adaptation, and the Windows player
at minimum size.

The release workflow runs formatting, static analysis, and the complete test
suite before any installer job. Pull-request runs are cancelled when a newer
commit supersedes them.

## Files not published

The repository deliberately excludes:

- Builds, APKs, IPAs, EXEs, and distribution packages.
- Local developer tool caches and their auxiliary directories.
- Signing keys, passwords, and local Android configuration files.
- Databases, downloaded music, thumbnails, and user backups.

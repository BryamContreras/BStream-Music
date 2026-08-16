# Changelog

## 1.2.4+124 — 2026-08-15

### Added

- Primary playback resolution and native-container downloads through
  `youtube_explode_dart`, with an explicit yt-dlp fallback for resolution,
  stream-validation, player-open, and download failures.
- Categorized InnerTube search for Songs, Videos, and Albums. Album, playlist,
  and mix results open a metadata and track-list page before playback creates
  the remote queue.
- Refreshable YouTube Music Home shelves with lazy collection lookups and
  bounded continuations of up to 100 detail tracks.
- CSV library import and export with BStream, MetroList, Harmony/RiMusic,
  Soundiiz, Exportify, and common title/artist/album/ISRC layouts. Imports are
  previewed, deduplicated, confirmed, and downloaded sequentially.
- Native Dart TikTok LIVE support on Android, Windows, Linux, and macOS. LIVE
  requests can play remotely without entering the Library or be downloaded and
  saved first through a persistent setting.
- Four persistent lyrics animation styles with alignment controls and an
  interactive preview.
- Mobile multi-selection for downloaded songs and playlist contents, including
  batch add, remove, and delete actions.
- Android ARMv7 release artifacts alongside ARMv8 and x86_64 on the existing
  Android 7.0 baseline.
- Song sharing from the full player with a stable `bstreammusic://track/...`
  link that opens BStream Music on Android, Windows, Linux, and macOS, and
  always includes a canonical YouTube URL as a manual fallback.

### Improved

- YouTube Explode now uses isolated, mutable client payloads and starts with a
  current VisionOS client plus watch-page context. The exact selected audio URL
  is verified with a bounded byte-range request before reaching the player.
- Audio selection prefers the default audio track and compatible M4A/AAC,
  while retaining WebM/Opus and other available audio-only containers as
  fallbacks without transcoding.
- yt-dlp fallback playback uses bounded managed downloads, strict cache limits,
  latest-request-wins cancellation, inactivity and total deadlines, and active
  source protection during hand-off.
- Playback opens, errors, queue mutations, and source changes are generation
  aware on just_audio and MediaKit, preventing stale operations from replacing
  or blocking the current song.
- Search categories load on demand; yt-dlp discovery fallback is represented as
  Videos only. Search returns up to 20 results, and empty tabs disappear when
  the query is cleared.
- Song, Video, and Album search categories now use a short accessible
  cross-fade, while album, playlist, and mix details reuse their artwork as a
  bounded, contrast-safe blurred header background.
- Remote track rows in Search and album, playlist, and mix details now expose
  Play/Pause plus More actions for Download and Add to playlist without
  forcing the full player open.
- Home hides empty Recently played and local Playlist sections and can refresh
  remote recommendations without hiding existing local content.
- Settings uses denser shared cards, a language selection dialog, grouped
  Import and Export actions, persistent LIVE storage behavior, and eighteen
  accent palettes including Brown in place of Amber.
- Library, Home, Search, mini-player, and full-player layouts now use bounded
  artwork decoding, lazy lists, 48 dp controls, and adaptive measurements for
  320 x 568 displays at up to 300% text scaling.
- Download identity, coalescing, partial-file publication, progress, and
  rollback now remain consistent across search, playback, playlists,
  favorites, CSV imports, and LIVE requests.
- Backup, restore, downloads, and migration share an operation coordinator so
  destructive storage work waits for active library commits.
- Final Android yt-dlp failures show the useful multiline extractor message
  directly instead of leading with the Java exception wrapper.
- Desktop installers no longer bundle the obsolete Python TikTok LIVE bridge;
  release validation rejects stale bridge artifacts and verifies all Android
  ABIs and bundled yt-dlp resources.
- Android and desktop keep up to three upcoming remote tracks prepared without
  restarting the current item; Android uses a rolling native media queue.
- Desktop remote playback uses a collision-resistant 12-hour application-cache
  LRU with 24-file, 256 MiB total, and 128 MiB per-track limits.
- Search artwork, lyrics, and player typography scale more consistently across
  compact and wide surfaces, while content and controls retain subtle
  accent-aware contrast in light and dark themes.

### Fixed

- Fixed an iOS Explode attempt that always failed when the package tried to add
  `visitorData` to an immutable nested payload.
- Fixed Quick picks without catalog duration losing the duration detected by
  ExoPlayer, which left the timeline at `--:--` and disabled seeking.
- Fixed manifests being accepted after validating a different stream than the
  AAC/WebM URL actually selected for playback.
- Fixed late backend errors, reversed asynchronous opens, and queue updates
  being attributed to a newer track.
- Fixed managed fallback pruning that could remove the source still being
  played while preparing its replacement.
- Fixed concurrent desktop cache publishers producing inconsistent entries for
  the same source across processes.
- Fixed duplicate local filenames and IDs for distinct tracks sharing artist
  and title metadata.
- Fixed failed database persistence leaving newly downloaded audio or thumbnail
  artifacts behind.
- Fixed player, timeline, mini-player, navigation, and LIVE queue overflows on
  narrow windows and large accessibility text sizes.

## 1.2.3+123 — 2026-08-09

### Added

- Android `Open with` support for local audio, including a folder-backed queue
  when media-library access and provider metadata are available.
- System, Light, and Dark themes with nine persistent accent palettes.
- Long-press queue reordering that preserves the active track and synchronizes
  Android's native media queue.
- Controlled preloading of only the next remote track.
- Song-count and total-duration summaries for playlists and downloaded songs.
- An inline search clear button that appears only while the field has text.
- A localized support section in Settings with a direct Ko-fi contribution
  link; the app remains free.

### Improved

- Unified high-quality artwork selection and proportional cropping across
  search, playback, playlists, downloads, and older YouTube thumbnails.
- Search now returns up to 15 results on Android and desktop.
- Accent-aware gradients, tabs, progress bars, lyrics, cards, menus, and player
  controls in both light and dark themes.
- Android remote playback with earlier source validation, preserved request
  headers, selective extractor updates, one retry, clearer HTTP/format errors,
  and restoration of the bundled extractor after a failed update retry.
- Android APK builds now bundle checksum-verified stable yt-dlp `2026.07.04`,
  matching the desktop release version. Existing installations migrate older
  bundled copies while preserving an equal or newer downloaded update.
- Long-session resource use with bounded artwork, thumbnail, remote-audio, and
  LRCLIB caches, request limits, and reduced position-update work.
- Backup restore validation for manifests, archive paths and limits, SQLite
  integrity, schema, and version, followed by staged activation and rollback.
- Recent playback retains its playlist context and queue changes remain aligned
  with native media controls.
- Release automation runs formatting, analysis, and tests before packaging and
  verifies the yt-dlp resource inside both Android APKs.

### Fixed

- Cancelling the custom sleep-timer dialog no longer raises an error.
- Artwork no longer changes crop or stretches after remote extraction or after
  saving a previously played track.
- Light-theme player buttons, contextual menus, lyrics controls, translucent
  surfaces, and accent contrast use theme-appropriate colors.
- The download status strip above the mini player was removed in favor of the
  integrated progress presentation.
- Back-button sizing, playlist navigation, old-thumbnail fallbacks, and several
  player layout inconsistencies were corrected.

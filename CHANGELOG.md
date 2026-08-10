# Changelog

## 1.2.3+123 — 2026-08-09

### Added

- Android `Open with` support for local audio, including a folder-backed queue
  when media-library access and provider metadata are available.
- System, Light, and Dark themes with twelve persistent accent palettes and a
  compact expandable color picker.
- Long-press queue reordering that preserves the active track and synchronizes
  Android's native media queue.
- Controlled sequential preloading of up to three upcoming remote tracks on
  Android and desktop.
- Song-count and total-duration summaries for playlists and downloaded songs.
- An inline search clear button that appears only while the field has text.
- A localized support section in Settings with a direct Ko-fi contribution
  link; the app remains free.
- A persistent one-button Normal/Centered lyrics alignment control on mobile
  and desktop.

### Improved

- Unified high-quality artwork selection and proportional cropping across
  search, playback, playlists, downloads, and older YouTube thumbnails.
- All 20 search thumbnails now load eagerly at their display-appropriate size,
  remain stable while scrolling, and search cards retain accent hover feedback
  during playback and downloads.
- Search now returns up to 20 results on Android and desktop.
- Accent-aware gradients, tabs, progress bars, lyrics, cards, menus, and player
  controls in both light and dark themes.
- Desktop song lyrics now scale across compact, standard, and wide windows to
  make better use of the available reading space.
- Lyrics lookup now ignores empty blocks and explicit karaoke/lyrics
  presentation labels while preserving songs actually titled `Karaoke` or
  `Lyrics` and leaving downloaded track metadata unchanged.
- Android remote playback with earlier source validation, preserved request
  headers, selective extractor updates, one retry, clearer HTTP/format errors,
  and restoration of the bundled extractor after a failed update retry.
- Android APK builds now bundle checksum-verified stable yt-dlp `2026.07.04`,
  matching the desktop release version. Existing installations migrate older
  bundled copies while preserving an equal or newer downloaded update.
- Long-session resource use with smaller bounded artwork, thumbnail, and LRCLIB
  caches. Android remote audio now prioritizes the current, next three, and
  previous tracks under strict limits and expires leftovers after 30 minutes.
- Desktop remote audio now uses an application-cache LRU with a 12-hour TTL,
  24-file and 256 MiB limits, a 128 MiB per-track cap, collision-resistant
  keys, atomic multi-instance publishing, and invalid-response filtering.
- Backup restore validation for manifests, archive paths and limits, SQLite
  integrity, schema, and version, followed by staged activation and rollback.
- Recent playback retains its playlist context and queue changes remain aligned
  with native media controls.
- Release automation runs formatting, analysis, and tests before packaging and
  verifies the yt-dlp resource inside both Android APKs.

### Fixed

- Desktop cache publication is now serialized both within the app process and
  across separate processes, preventing concurrent formats for one source from
  creating inconsistent cache results on Linux and macOS.
- Player, search/list, playlist, and library content text now receives a very
  subtle accent tint in both themes. Tab headings share the standard themed
  foreground, while lyrics remain unchanged.
- Dark-mode content text, including player, library, and playlist titles, uses
  a true-white base with only a barely perceptible accent tint.
- Light-mode player controls and song titles now use softer,
  accent-tinted foreground colors.
- Popup and submenu icons follow the selected accent in both themes, with a
  subtler accent tint on menu text in light and dark modes.
- The volume slider track and thumb now follow the selected accent color.
- Android transitions between remote tracks, whether automatic or requested
  from media controls, now use a rolling native queue. The foreground audio
  service stays active across track boundaries after the app is removed from
  recent tasks, and the queue refills as playback advances.
- Cancelling the custom sleep-timer dialog no longer raises an error.
- Artwork no longer changes crop or stretches after remote extraction or after
  saving a previously played track.
- Light-theme player buttons, contextual menus, lyrics controls, translucent
  surfaces, and accent contrast now use theme-appropriate colors.
- The download status strip above the mini player was removed in favor of the
  integrated progress presentation.
- Back-button sizing, playlist navigation, old-thumbnail fallbacks, and several
  player layout inconsistencies were corrected.

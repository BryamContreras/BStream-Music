# Changelog

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
  surfaces, and accent contrast now use theme-appropriate colors.
- The download status strip above the mini player was removed in favor of the
  integrated progress presentation.
- Back-button sizing, playlist navigation, old-thumbnail fallbacks, and several
  player layout inconsistencies were corrected.

# Changelog

## 1.2.6+126 — 2026-09-02

### Changed

- Added the native iOS 13+ runner and completed the mobile platform routing for
  playback, background audio/Now Playing, secure embedded account login,
  headless WebView challenges, downloads, TikTok LIVE, deep links, local
  Media Library songs and artwork, and document-picker backup/CSV export. iOS
  now rebuilds sandbox-relative media paths after container changes, uses the
  bounded mobile stream cache, and is validated in CI with focused tests plus
  unsigned simulator and Release device builds. CI packages the device build
  as `BStream-Music-<version>-iOS-unsigned.ipa` for use as input to external
  signing or sideloading tools; the artifact is not directly installable until
  such a tool signs or re-signs it. Existing Android, Windows, Linux, and macOS
  platform paths remain unchanged.
- Added an optional cross-platform Liquid Glass appearance for application
  surfaces and the mini player, including neutral transparency, continuous
  superellipse clipping, uniformly backdrop-adaptive edge refraction, and
  hover-only droplets implemented entirely in Flutter. Song and Settings
  cards retain their regular Material treatment, and tab headers remain
  edge-to-edge instead of becoming rounded glass cards. Light mode now adds a
  milky-white veil and an exterior-only shadow so controls remain legible
  without giving translucent light surfaces a gray cast. Its navigation icons
  and mini-player metadata use pure black for reliable contrast. Dark glass
  now uses a lighter neutral wash and hover droplet so more backdrop chroma
  remains visible without changing its adaptive rim. Edge-to-edge tab headers
  now use one flat glass wash without the capsule shadow, Fresnel rim, or
  duplicate Material overlays that previously appeared as stacked rectangles.
  Accent and Transparent optics remain unchanged.
- In Accent and Transparent modes, bottom navigation now hides smoothly during
  downward browsing and returns on upward scrolling while the mini player
  occupies the released space. Liquid Glass instead compacts into an animated
  Home, mini-player, and detached Search row; Home or upward scrolling expands
  the full Home, Local, Library, and Settings menu again. The compact mini
  player now keeps its full translated hit-test area, so taps always open the
  player instead of reaching the browsing content underneath.
- The compact Liquid Glass Home control is now icon-only, matching the detached
  Search control while retaining its full accessible label and tap target.
- Appearance settings now offer BStream Music and Apple Music Style full-player
  layouts. The Apple layout uses the artwork-blurred background, compact square
  cover, inline favorite/menu actions, remaining-time seek bar, Apple-like
  transport and volume rows, and the supported Lyrics, shuffle, repeat, and
  queue actions. Its cover flexes so standard phones from 320x568 upward and
  mobile landscape keep the complete player in one non-scrolling viewport;
  only extreme reduced-height or 300-percent accessibility layouts retain a
  scroll fallback. The Apple layout uses uniform 7 px progress and volume
  tracks without circular indicators, while BStream Music retains its animated
  wave seek bar and compact volume thumb. Metadata actions align with the
  artist row, transport controls use the reference proportions, and time
  labels follow the track insets. Share now lives inside the overflow menu in
  both layouts, while BStream Music also retains its direct shortcut beside
  Favorites. The Apple trigger keeps a 48 px touch target without applying that
  constraint to the popup route. Mobile Apple spacing now places the cover
  closer to the grabber and grows it responsively while preserving safe-area
  clearance, the non-scrolling short-phone layout, and landscape adaptation.
- Added an Animated artwork option under Appearance > Player, enabled by
  default for both new and existing installations. The large player cover uses
  independent closed loops for a 28-second zoom, 31-second 7 x 4 px pan, and
  35-second 3D drift capped at +/-0.3 degrees X, +/-0.4 degrees Y, and +/-0.12
  degrees Z with 0.00085 perspective. A viewport-aware crop guard prevents
  moving edges from becoming visible. Pausing playback freezes all motion at
  its current phase and resuming continues without a jump. It remains static
  for reduced motion, hidden player tabs, app backgrounding, missing artwork,
  or when the preference is disabled.
- Mobile Lyrics now morphs smoothly between its portrait header and landscape
  playback companion after the first stable rotation frame, while preserving
  the same lyrics scroll state. Its companion uses the same uniform linear
  Apple seek track without a thumb in every player style. Reduced-motion mode
  switches immediately, and the active Android lyric now keeps a clean white
  foreground with a mobile-compensated layered outer glow that remains as visible as desktop,
  without the former foreground shader or an additional render layer.
- Renamed the visible appearance labels to Liquid Glass Style and Flotante;
  their persisted `liquidGlass` and `capsule` values remain unchanged.
- Removed every resolver/runtime dependency on `youtube_explode_dart`, yt-dlp,
  Deno, QuickJS, and Android's youtubedl runtime. Catalog access, playback, and
  downloads now use an in-process modular Dart InnerTube architecture on every
  platform, with one shared resolver for playback and downloads.
- Added maintained client profiles with correctness-first routing, deep ranged
  media validation, health cooldowns, latency tracking, and automatic fallback.
- Added independent EJS `s`/`n` challenge solving and Web BotGuard PO-token
  support through an isolated headless system WebView, with no custom Kotlin
  extractor or bundled resolver executable.
- Added page-specific dynamic player bootstrap, three independently validated
  tokenless profiles, an EJS-backed embedded fallback, anti-bot visitor/player
  PO escalation, fail-closed integrity tokens, alternate coherent attestation,
  and capability-level EJS/WebPO circuit breaking.
- Added raw/tokenless and full resolved client matrices. Raw gated clients are
  now reported as skipped instead of failed, and every success requires a deep
  or end-of-file CDN range probe. Strict resolved runs isolate state and enforce
  success thresholds per profile with separate cold/warm latency reporting.
- Downloads now prefer audio-only InnerTube formats, retain a validated muxed
  `.mp4` only as the last resort, and use a resumable `dart:io` transfer with
  strong representation validators, bounded retries, safe partial files, and
  atomic promotion.

## 1.2.5+125 — updated 2026-08-22

### Added

- Optional YouTube Music account sign-in with an isolated browser, encrypted
  on-device session storage, account/channel selection, a Home avatar, and an
  explicit warning that the integration is unofficial and unaffiliated with
  Google. BStream never receives or stores the account password.
- Bidirectional local/YouTube Music playlist synchronization with stable IDs,
  occurrence-safe duplicates, private-by-default remote creation, three-way
  merging, bounded automatic retries, and explicit conflict review.
- A per-account first-sync confirmation keeps every local playlist untouched
  until the user explicitly chooses **Keep and sync**; choosing **Not now**
  performs no remote reads or writes and can be revisited from the account menu.
- Account-free Home personalization backed by qualified local listening
  history. BStream combines YouTube Music `/next`, related shelves, generated
  mixes, and exact artist pages into **Because you listened**, **Your mixes**,
  **New for you**, and **Discovery for you** sections.
- Persistent anonymous InnerTube visitor data, related-result caches, and an
  instant stale-while-revalidate Home feed so recommendations survive restarts
  while still refreshing in the background.
- Privacy controls to pause recommendation learning or clear listening signals
  and personalized caches without deleting downloads, favorites, or playlists.
- A bounded InnerTube retry policy, crash-safe download-directory migration
  journal, playback-history retention, and CI security/size gates for release
  artifacts and dependencies.

### Improved

- Synced playlists can retain remote songs without downloading them. Playback
  prefers an available download and falls back to the matching stream, while
  imported artwork and metadata remain visible offline when locally cached.
- Playlist rows show a compact cloud before the artist only when no usable
  downloaded audio exists; cached artwork and empty files do not count as a
  download.
- Removing a synchronized playlist is local-only by default; deleting it from
  YouTube Music requires a separate confirmation and an editable playlist from
  the active account. Ambiguous writes are never blindly repeated.
- YouTube Music artist browse identifiers now survive search, playback,
  downloads, database migrations, and app restarts, allowing new-release
  recommendations to use exact artist identities instead of name guesses.
- Listening history now qualifies a play only after 40 percent or 30 seconds,
  whichever comes first, and covers both remote streams and catalog-backed
  downloads without counting seeks or accidental taps.
- Personalized AutoMix cards now load their real YouTube Music radio queue,
  and recommendation shelves remain navigable with Previous/Next even when
  downloaded and streaming entries appear together or start with one item.
- Active streams now retry the complete `youtube_explode_dart` → yt-dlp chain
  twice with bounded backoff after transient connection loss. Duplicate player
  errors share one retry budget, user navigation cancels stale attempts, and a
  terminal TikTok LIVE request advances to the next ready item without looping.
- Player playback, queue navigation, retry, prefetch, history, and crossfade
  responsibilities are split into focused coordinators instead of one
  3,600-line controller. Stale queue work and native option races are now
  generation-aware.
- Optional native services initialize after the first frame and retry only the
  failed integration. Japanese romanization loads its dictionary lazily from a
  compressed asset and releases the expanded worker after an idle timeout.
- Android runtime yt-dlp updates are stable-channel by default and must match
  the official release checksum and the version reported by the executable;
  invalid copies fall back to the bundled verified binary.
- Backup restore validates entry counts, individual and expanded sizes,
  compression ratio, duplicate paths, manifest, and SQLite schema before
  replacing active data.

### Fixed

- Mobile Lyrics no longer duplicates the mini-player; its header artwork acts
  as Back and the larger Play/Pause control remains reachable at narrow widths.
- The mini-player stays attached to bottom navigation when the software
  keyboard opens instead of retaining an extra system-navigation inset.
- Back from a player opened through a notification or launcher entry now
  returns to Home instead of closing the application; Queue retains its own
  nested Back behavior.

### Initial 1.2.5 release — 2026-08-20

#### Added

- Dual-deck crossfade playback on Android and desktop with a persistent,
  accessible whole-second duration control from 1 through 15 seconds.
- Optional lyrics romanization that keeps each original line above a smaller
  transliteration. Japanese, Korean, Chinese, Cyrillic, Arabic, and Hebrew can
  be selected independently and are represented in the live settings preview.
- Android EJS challenge solving through the bundled QuickJS runtime, optional
  BotGuard WebView PO-token generation, and a shared Deno solver on desktop for
  reinforced `youtube_explode_dart` requests.
- Desktop Space-key Play/Pause handling for both player surfaces while leaving
  Search and other focused editable fields untouched.

#### Improved

- YouTube audio resolution now follows a deterministic client ladder, retries
  solver-dependent clients only when needed, validates the exact selected
  stream, and reports every attempted client when direct resolution fails.
- Downloads try all reinforced `youtube_explode_dart` candidates before a
  single serialized yt-dlp fallback. Resolution and transfers use bounded
  deadlines, clean partial files, retain native containers, and avoid falling
  back for local filesystem failures.
- CSV restoration processes up to three tracks concurrently while keeping
  playlist membership and source order deterministic, reusing existing files,
  honoring cancellation, and continuing past individual failures.
- Japanese romanization uses token boundaries instead of arbitrary character
  chunks; paired original and romanized lyrics remain scrollable without
  overflow on narrow displays and large text scales.
- Full and mini-player layouts are denser and more consistent across Android
  and desktop, with clearer primary controls, closer timeline labels, safe CJK
  metadata wrapping, and a neutral accent-tinted desktop mini-player surface
  independent of the full-player artwork background.
- Library overview cards use the same larger artwork geometry as track-detail
  rows, Settings cards share compact spacing and surfaces, and the Windows
  playback queue uses more of the available width.
- Search title changes and expandable Crossfade settings use bounded accessible
  transitions, including reduced-motion behavior without layout jumps.
- Android hides the desktop-only download-folder control. CSV export profiles
  present only their compatibility names: BStream Music, MetroList,
  Harmony/RiMusic, and Soundiiz.

#### Fixed

- Legacy no-animation lyrics preferences now migrate to Smooth, and the
  redundant play control was removed from the lyrics header on every platform.
- Crossfade preparation, promotion, seeks, pause/resume, Stop, disabling, and
  disposal are generation-aware so stale deck operations cannot replace the
  current song or leak a prepared player.
- Concurrent library downloads now coalesce identical tracks and publish one
  consistent local file instead of racing duplicate writes.
- Rapid tab changes no longer retain stale accessibility semantics nodes that
  could trigger Flutter AXTree update errors.
- Compact player artwork, multiline titles, timelines, and controls avoid the
  observed bottom and horizontal overflows on small Android screens.

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
- Song sharing from the full player with one canonical HTTPS link recognized
  by chat applications. YouTube Music is preferred for InnerTube catalog
  tracks, while generic video results retain a regular YouTube watch URL.

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
  Import and Export actions, persistent LIVE storage behavior, an Application
  information entry with an organized About detail for version, support, and
  the official GitHub repository, and eighteen accent palettes including Brown
  in place of Amber.
- Library, Home, Search, mini-player, and full-player layouts now use bounded
  artwork decoding, lazy lists, 48 dp controls, and adaptive measurements for
  320 x 568 displays at up to 300% text scaling.
- Download identity, coalescing, partial-file publication, progress, and
  rollback now remain consistent across search, playback, playlists,
  favorites, CSV imports, and LIVE requests.
- TikTok LIVE now filters ordinary chat before decoding full viewer profiles,
  acknowledges busy WebSocket batches before routing events, and resolves up
  to three music requests concurrently while committing the queue in original
  command order. A bounded search deadline prevents one stalled lookup from
  blocking the entire queue without cutting off an active download.
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

# InnerTube playback and downloads

BStream resolves YouTube media without `youtube_explode_dart`, yt-dlp, Kotlin
extractors, or an external executable. Catalog requests remain in
`innertube_search_service.dart`; playback is isolated under
`lib/services/youtube_music/playback/` so client rotations and challenge
changes do not affect search parsing.

## Resolution pipeline

1. Parse and validate the video ID without accepting lookalike hosts.
2. Bootstrap the page that belongs to that identity (`watch`, `embed`, Music,
   mobile, or TV) and atomically capture its visitor identity, player URL,
   signature timestamp, client version, and embedded context.
3. Request `/youtubei/v1/player` with one explicit client profile and the
   matching dynamic version when that profile permits rotation.
4. Reject a mismatched video ID, DRM/SABR-only data, and non-playable status.
5. Select compatible audio deterministically.
6. Solve `s` and `n` through pinned EJS 0.8.0 when present. Empty output and an
   unchanged `n` are rejected before they can enter the solver cache.
7. Generate player/GVS WebPO tokens through the Dart BotGuard provider when a
   web client requires them. Player and GVS bindings are owned by each client
   profile; MWEB/WEB/WEB_REMIX try video-bound GVS then visitor-bound GVS on a
   confirmed PO rejection, while WEB_REMIX keeps its player token
   visitor-bound.
8. Probe the exact selected URL at an offset of at least 3 MiB, or the last
   byte for a smaller representation.
9. Return the URL only after that probe succeeds. Repeatedly failing clients
   enter a bounded cooldown and healthy fallbacks are re-ordered by EWMA
   latency.

`s`/`n` deciphering and PO tokens are independent concerns. A ciphered URL does
not imply that a PO token is required, and WebPO is never attached to Android
or iOS profiles that require a platform attestation.

The implementation follows behavior, not source code, from Zemer Cipher.
Zemer is GPL-3.0 while BStream is BSD-2-Clause, so no Zemer implementation was
copied or translated. EJS is the upstream Unlicense solver published by
yt-dlp. The exact 0.8.0 release modules are bundled as Base64 assets and their
decoded bytes are verified by SHA-256 before execution; a verified download
of the same release is retained only as a recovery fallback.

The WebPO harness and Dart orchestration are original protocol-level code. The
maintained BgUtils and bgutil provider projects were used as interoperability
references; their source code was not copied into this repository. Therefore
no GPL provider code is bundled and the local harness is not a translation of
those projects.

Metrolist/InnerTubeX, OpenTune, Echo Music, and SimpMusic were also reviewed as
behavioral references for client fallback, bootstrap separation, and failure
handling. BStream's implementation remains a clean-room Dart design; no Kotlin
or GPL application source was copied or mechanically translated.

## WebPO bootstrap

The primary bootstrap is one atomic `https://www.youtube.com/` snapshot:

1. Parse strict JSON from `ytcfg.set(...)` without evaluating page code.
2. Read `EVENT_ID` and `VISITOR_DATA` (or the matching
   `INNERTUBE_CONTEXT.client.visitorData`) from that same config.
3. Decode only the JavaScript string escapes in `window.ytAtN(...).R`, parse
   its JSON, and read `bgChallenge`.
4. Fetch the trusted Google interpreter in Dart and inject the exact
   `yt.config_`, including `EVENT_ID`, before taking the BotGuard snapshot.
5. Install the BotGuard VM using its current nine-argument contract and five
   isolated logger callbacks, then exchange the snapshot at
   `jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT`. If that
   route is unavailable or returns only degraded output, try YouTube's
   compatible `/api/jnn/v1/GenerateIT` route.

GenerateIT must return a full integrity token before BStream initializes the
per-binding minter. A `websafeFallbackToken` is not content-bound and is never
accepted as a player or GVS token. If both routes withhold full integrity for
the homepage challenge, BStream creates one fresh, coherent `att/get` session
and tries both GenerateIT routes again. If that independent session also
withholds integrity, the provider fails closed; a shared WebPO circuit breaker
skips the remaining WebPO profiles for two minutes and immediately continues
through tokenless fallbacks. That capability failure does not poison individual
client health.
BotGuard is attestation rather than a bypass, so full integrity can legitimately
depend on the runtime, network, and Google-side policy; production therefore
never relies on a WebPO-only client as its sole route.

When the homepage snapshot has no usable challenge, or its challenge produces
only withheld integrity, the provider falls back as a unit: it obtains
visitorData from `music.youtube.com/sw.js_data` and sends that same identity in
`/youtubei/v1/att/get?prettyPrint=false` with `ENGAGEMENT_TYPE_UNBOUND`. The
legacy `/api/jnn/v1/Create` route is not used.

Both the requested and post-redirect interpreter URLs must remain on the
allowlisted HTTPS Google/YouTube host families before any bytes are executed.
The challenge's `interpreterHash` is retained as protocol metadata, but is not
treated as a checksum: the current protocol does not identify its digest
algorithm or canonical byte representation.

## Client order

The maintained production order is:

1. `visionOS` — current tokenless/JS-less default.
2. `androidSdkless` — independent tokenless/JS-less fallback.
3. `visionOS01` — a second VisionOS identity kept fallback-only because its
   content coverage is narrower, even though it is fast.
4. `webEmbedded` — tokenless GVS with dynamic embedded bootstrap and EJS;
   limited to embeddable videos.
5. `mweb` — preferred EJS plus WebPO fallback; ordinary WEB commonly exposes
   only SABR.
6. `webMusic` — EJS plus WebPO.

EJS and WebPO each have an independent shared two-minute circuit breaker. A
runtime/module failure is attempted once, skips the remaining profiles that
need that capability, and does not lower the health score of otherwise healthy
client identities. Breaker state is checked again before every profile so a
concurrent resolution observes it immediately.

`tv`, the version-pinned `tvDowngraded`, `tvSimply`, and ordinary `web` remain
experimental probes rather than cold-path fallbacks. Current signed-out TV
responses are `UNPLAYABLE` before EJS, while ordinary WEB is SABR-only. The
downgraded TV profile deliberately rejects dynamic version replacement so it
remains an independent escape hatch.

iOS and Android VR remain described for diagnostics but are not production
fallbacks because WebPO cannot replace iOSGuard/DroidGuard. Android VR is
disabled after its formats began returning 403 consistently.

Downloads first set `requireAudioOnly` and continue through the ladder for a
compact audio representation. If a playable response proves that only a
direct muxed stream is available, the downloader repeats normal deep
validation and saves that last-resort payload with its real `.mp4` extension;
it is never mislabeled as `.m4a` and no transcoder is required.

## Benchmark

Run:

```text
dart run tool/innertube_playback_benchmark.dart --rounds=2
```

The raw benchmark ranks correctness before speed. A success is a ranged media
read beyond 3 MiB, not a HEAD request or first-byte probe. EJS-, WebPO-, and
platform-attestation-gated samples are reported as `SKIP`, not failures, so a
raw result is never mistaken for the complete production stack. After adding
one coherent best-effort visitor bootstrap, the 2026-08-31
five-video/two-round run was:
`visionOS` 10/10 (median 310 ms), `visionOS01` 10/10 (313 ms), and
`androidSdkless` 10/10 (395 ms). `visionOS` therefore remains the default;
`visionOS01` is also intentionally fallback-only. Network/IP behavior changes,
so rerun the tool whenever profiles or versions are updated.

The complete Flutter matrix forces each selected profile independently through
bootstrap, EJS/PO when applicable, player parsing, and the deep CDN probe:

```text
flutter test -d windows --dart-define=BSTREAM_LIVE_INNERTUBE_MATRIX=true --dart-define=BSTREAM_INNERTUBE_MATRIX_ROUNDS=1 --dart-define=BSTREAM_INNERTUBE_MATRIX_PROFILES=visionOS,androidSdkless,visionOS01,webEmbedded integration_test/innertube_profile_matrix_live_test.dart
```

Each profile receives isolated visitor/EJS/PO state, and samples label cold
versus warm latency. Strict mode rejects capability skips and requires every
stable or explicitly selected profile to meet the per-profile success floor
(80% by default, configurable with
`BSTREAM_INNERTUBE_MATRIX_MIN_SUCCESS_PERCENT`), so one healthy profile cannot
hide another profile's regression.

On the same date, the hardened strict Windows matrix passed 19/20 overall:
the three direct clients passed 15/15 and `webEmbedded` passed 4/5. An isolated
`webEmbedded` run also passed 5/5, showing real CDN/enforcement fluctuation and
why the production path must retain several independently validated fallbacks.

The opt-in WebPO integration checks the live bootstrap/interpreter and performs
one live GenerateIT mint without printing visitor, challenge, or token values.
It accepts either full integrity-backed tokens or the explicitly classified
fail-closed state; add `BSTREAM_LIVE_WEB_PO_STRICT=true` when a release gate
must require full integrity in that environment:

```text
flutter test --dart-define=BSTREAM_LIVE_WEB_PO=true integration_test/web_po_bootstrap_live_test.dart
```

The production-ladder integration additionally requires a deep CDN probe:

```text
flutter test -d windows --dart-define=BSTREAM_LIVE_INNERTUBE=true integration_test/innertube_playback_live_test.dart
```

## Platform behavior

BotGuard and EJS are orchestrated in Dart. Their JavaScript executes in a
headless `flutter_inappwebview` runtime on Android, Windows, and macOS. Linux
has no backend in the pinned stable plugin, so BStream cleanly limits Linux to
the three JS-less tokenless profiles (`visionOS`, `androidSdkless`, and
`visionOS01`) instead of invoking Deno, QuickJS, Kotlin, or yt-dlp. The runtime
boundary remains injectable so Linux EJS/WebPO can be enabled after a stable
WPE backend passes native build and smoke tests; it is not presented as current
platform parity.
Every runtime document receives a CSP before its first script that denies
connect, media, frame, worker, form, and navigation access; the native delegate
also rejects navigation and popups. Cache, DOM/database storage, shared and
third-party cookies are disabled. Windows and macOS additionally use a private
WebView data store. Android cannot enable this plugin's `incognito` flag safely
because the platform implementation clears cookies for every process WebView,
including the authenticated account view; this limitation is contained by the
offline CSP and disabled storage settings. A renderer crash or JavaScript
timeout retires the runtime so the next attempt starts from a clean document.

## Updating

- Update versions, numeric IDs, capabilities, and ordering only in
  `innertube_client_profile.dart`.
- Update the EJS assets, version, URLs, and hashes together in
  `ejs_solver.dart`, then verify the packaged-asset test before release.
- Keep PO cache keys separated by binding type and binding value.
- Keep both token-result and per-generator mint caches bounded; concurrent
  requests share in-flight work and WebView calls are serialized.
- Keep `visitorData`, `EVENT_ID`, and `ytAtN` challenge coupled to the same
  homepage response; never refresh one of them independently.
- Run the playback unit suite, the resumable transfer suite, full analyzer,
  and the live deep-range benchmark before promoting a profile.

Protocol references:

- <https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/youtube/_base.py>
- <https://github.com/yt-dlp/ejs>
- <https://github.com/LuanRT/BgUtils>
- <https://github.com/Brainicism/bgutil-ytdlp-pot-provider>
- <https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide>
- <https://github.com/ZemerTeam/zemer-cipher>
- <https://github.com/MetrolistGroup/innertubex/commit/44ca1ad23d69c09e98511ec6aaa230da23b32e2a>
- <https://github.com/Arturo254/OpenTune/commit/00bc643a94fd35ee5fc41db6152adfc0652e3edc>
- <https://github.com/EchoMusicApp/Echo-Music/tree/9e161bf6f74d60df7f85f47d82c29df499ded477>
- <https://github.com/maxrave-dev/core/tree/8db86c90dca67e36311f97a39525810f9ada8c6f>

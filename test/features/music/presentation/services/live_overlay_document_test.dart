import 'package:bstream_music/features/music/presentation/services/live_overlay_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LIVE overlay is transparent and connects to the local websocket', () {
    expect(liveOverlayHtml, contains('background: transparent !important'));
    expect(
      liveOverlayHtml,
      contains(
        r"new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`)",
      ),
    );
    expect(liveOverlayHtml, contains('items.slice(0, 5)'));
    expect(liveOverlayHtml, contains("className = 'artwork fallback'"));
    expect(liveOverlayCanvasWidth, 1280);
    expect(liveOverlayCanvasHeight, 760);
  });

  test(
    'LIVE overlay omits requester/current/ready badges and labels pending states',
    () {
      expect(liveOverlayHtml.toLowerCase(), isNot(contains('requestedby')));
      expect(liveOverlayHtml.toLowerCase(), isNot(contains('chroma')));
      expect(liveOverlayHtml, isNot(contains('AHORA')));
      expect(liveOverlayHtml, isNot(contains('LISTA')));
      expect(liveOverlayHtml, contains('resolving: localizedLabels.resolving'));
      expect(
        liveOverlayHtml,
        contains('downloading: localizedLabels.downloading'),
      );
    },
  );

  test('LIVE overlay localizes all visible document labels from state', () {
    expect(liveOverlayHtml, contains("resolving: 'BUSCANDO'"));
    expect(liveOverlayHtml, contains("resolving: 'SEARCHING'"));
    expect(liveOverlayHtml, contains("downloading: 'CARGANDO'"));
    expect(liveOverlayHtml, contains("downloading: 'LOADING'"));
    expect(liveOverlayHtml, contains("untitled: 'Sin título'"));
    expect(liveOverlayHtml, contains("untitled: 'Untitled'"));
    expect(liveOverlayHtml, contains('state && state.labels'));
    expect(liveOverlayHtml, contains('document.documentElement.lang = locale'));
    expect(
      liveOverlayHtml,
      contains('String(item.title || localizedLabels.untitled)'),
    );
  });

  test('LIVE overlay places the brand logo before the current track title', () {
    expect(liveOverlayHtml, isNot(contains('id="now-playing-header"')));
    expect(liveOverlayHtml, isNot(contains('Reproduciendo')));
    expect(liveOverlayHtml, isNot(contains('Now Playing')));
    expect(
      liveOverlayHtml,
      contains('<section id="queue" aria-live="polite"></section>'),
    );
    expect(liveOverlayHtml, contains("titleRow.className = 'title-row'"));
    expect(liveOverlayHtml, contains("titleLogo.className = 'title-logo'"));
    expect(liveOverlayHtml, contains("titleLogo.src = '/bstream-icon.png'"));
    expect(liveOverlayHtml, contains("titleLogo.alt = ''"));
    expect(liveOverlayHtml, contains('titleRow.append(titleLogo, title)'));
    expect(liveOverlayHtml, contains('details.append(titleRow, artist)'));
    expect(
      liveOverlayHtml,
      contains("String(item.status || '').toLowerCase() === 'playing'"),
    );
    expect(
      liveOverlayHtml,
      contains("card.classList.toggle('is-playing', playing)"),
    );
    expect(liveOverlayHtml, contains('.track.current.is-playing .title-logo'));
    expect(liveOverlayHtml, contains('width: 30px'));
    expect(liveOverlayHtml, contains('height: 30px'));
    expect(liveOverlayHtml, contains('width: 24px'));
    expect(liveOverlayHtml, contains('height: 24px'));
  });

  test('LIVE overlay keeps the current card compact and shows both times', () {
    expect(liveOverlayHtml, contains('min-height: 124px'));
    expect(liveOverlayHtml, isNot(contains('min-height: 188px')));
    expect(liveOverlayHtml, contains('border-radius: 12px'));
    expect(liveOverlayHtml, contains("elapsed.className = 'elapsed'"));
    expect(liveOverlayHtml, contains("duration.className = 'duration'"));
    expect(liveOverlayHtml, contains('state.positionMs'));
    expect(liveOverlayHtml, contains('state.durationMs'));
    expect(liveOverlayHtml, contains("formatTime(durationMs) : '--:--'"));
    expect(liveOverlayHtml, contains('font-size: 14px'));
  });

  test('LIVE overlay makes only the card backgrounds subtly transparent', () {
    final trackRule = RegExp(
      r'\.track \{([\s\S]*?)\n    \}',
    ).firstMatch(liveOverlayHtml)!.group(1)!;

    expect(liveOverlayHtml, contains('--card-background-opacity: .88'));
    expect(liveOverlayHtml, contains('--current-card-background-opacity: .92'));
    expect(liveOverlayHtml, contains('.track::before'));
    expect(
      liveOverlayHtml,
      contains('opacity: var(--card-background-opacity)'),
    );
    expect(
      liveOverlayHtml,
      contains('opacity: var(--current-card-background-opacity)'),
    );
    expect(liveOverlayHtml, contains('.track > .details'));
    expect(liveOverlayHtml, contains('.track.current::after'));
    expect(
      RegExp(r'^\s*opacity\s*:', multiLine: true).hasMatch(trackRule),
      isFalse,
      reason: 'Opacity on .track would also fade text, artwork, and progress.',
    );
  });

  test('LIVE overlay reconciles cards by id without rebuilding the queue', () {
    expect(liveOverlayHtml, contains('const cardsByKey = new Map()'));
    expect(liveOverlayHtml, contains('const reconcileCards = items =>'));
    expect(liveOverlayHtml, contains('const stageExit ='));
    expect(liveOverlayHtml, contains('const animateMove ='));
    expect(liveOverlayHtml, contains('const animateEntry ='));
    expect(liveOverlayHtml, contains('card.getBoundingClientRect()'));
    expect(
      liveOverlayHtml,
      contains("typeof card.getAnimations !== 'function'"),
    );
    expect(liveOverlayHtml, contains('cancelCardAnimations(card)'));
    expect(liveOverlayHtml, isNot(contains('queue.replaceChildren()')));
    expect(liveOverlayHtml, contains(".track.current:not(.leaving)"));
  });

  test('LIVE overlay crossfades artwork only after the new image loads', () {
    expect(liveOverlayHtml, contains("image.addEventListener('load'"));
    expect(liveOverlayHtml, contains("img:not(.pending-artwork)"));
    expect(liveOverlayHtml, contains('Promise.allSettled'));
    expect(liveOverlayHtml, contains('reducedMotion.matches'));
  });
}

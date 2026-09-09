/// Self-contained document served by the local LIVE overlay server.
///
/// The page deliberately has no canvas/background color: browser sources can
/// composite the cards directly over a scene without chroma keying.
const liveOverlayCanvasWidth = 1280;
const liveOverlayCanvasHeight = 760;

const liveOverlayHtml = r'''<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>BStream LIVE</title>
  <style>
    :root {
      color-scheme: dark;
      --accent: #f5f7f5;
      --accent-dark: #59615c;
      --card: rgb(19, 24, 32);
      --card-soft: rgb(22, 27, 36);
      --card-background-opacity: .88;
      --current-card-background-opacity: .92;
      --text: #fff;
      --muted: rgba(255, 255, 255, .72);
    }

    * { box-sizing: border-box; }

    html, body {
      width: 100%;
      min-height: 100%;
      margin: 0;
      overflow: hidden;
      background: transparent !important;
    }

    body {
      font-family: Inter, Roboto, "Segoe UI", sans-serif;
      color: var(--text);
      text-rendering: geometricPrecision;
    }

    #overlay {
      position: relative;
      width: min(1192px, calc(100vw - 40px));
      margin: 28px auto;
      filter: drop-shadow(0 12px 22px rgba(0, 0, 0, .30));
    }

    #queue {
      position: relative;
      display: grid;
      gap: 11px;
    }

    #queue:empty { display: none; }

    .track {
      position: relative;
      display: grid;
      grid-template-columns: 94px minmax(0, 1fr);
      align-items: center;
      min-height: 104px;
      padding: 11px 20px 11px 11px;
      margin-inline: 10px;
      overflow: hidden;
      isolation: isolate;
      border: 1px solid rgba(255, 255, 255, .14);
      border-color: color-mix(in srgb, var(--accent) 20%, transparent);
      border-radius: 12px;
      background: transparent;
      box-shadow:
        inset 0 1px 0 rgba(255, 255, 255, .08),
        0 6px 16px rgba(0, 0, 0, .18);
      will-change: transform, opacity;
    }

    .track::before {
      content: "";
      position: absolute;
      z-index: 0;
      inset: 0;
      border-radius: inherit;
      background: var(--card-soft);
      background:
        linear-gradient(115deg,
          color-mix(in srgb, var(--accent-dark) 42%, #111722 58%),
          color-mix(in srgb, var(--card-soft) 94%, var(--accent) 6%));
      opacity: var(--card-background-opacity);
      pointer-events: none;
    }

    .track > .artwork,
    .track > .details,
    .track > .status {
      position: relative;
      z-index: 1;
    }

    .track.has-status {
      grid-template-columns: 94px minmax(0, 1fr) 116px;
    }

    .track.current {
      grid-template-columns: 112px minmax(0, 1fr);
      min-height: 124px;
      padding: 11px 20px 11px 11px;
      margin-inline: 10px;
      border-radius: 14px;
      border-color: color-mix(in srgb, var(--accent) 38%, transparent);
      background: transparent;
      box-shadow:
        inset 0 1px 0 rgba(255, 255, 255, .12),
        0 10px 24px rgba(0, 0, 0, .26);
    }

    .track.current::before {
      background: var(--card);
      background:
        radial-gradient(circle at 12% 20%,
          color-mix(in srgb, var(--accent) 19%, transparent),
          transparent 43%),
        linear-gradient(115deg,
          color-mix(in srgb, var(--accent-dark) 58%, #111722 42%),
          color-mix(in srgb, var(--card) 92%, var(--accent) 8%));
      opacity: var(--current-card-background-opacity);
    }

    .track.current::after {
      content: "";
      position: absolute;
      z-index: 2;
      inset: 0 auto 0 0;
      width: 4px;
      background: linear-gradient(180deg, var(--accent), var(--accent-dark));
    }

    .artwork {
      position: relative;
      width: 82px;
      height: 82px;
      overflow: hidden;
      border-radius: 10px;
      background: #252b35;
      background:
        linear-gradient(145deg,
          color-mix(in srgb, var(--accent) 36%, #252b35),
          color-mix(in srgb, var(--accent-dark) 48%, #10141b));
      box-shadow: 0 4px 12px rgba(0, 0, 0, .28);
    }

    .current .artwork {
      width: 100px;
      height: 100px;
      border-radius: 12px;
    }

    .artwork img {
      display: block;
      width: 100%;
      height: 100%;
      object-fit: cover;
    }

    .artwork img.pending-artwork {
      position: absolute;
      inset: 0;
    }

    .artwork.fallback::after {
      content: "♪";
      display: grid;
      width: 100%;
      height: 100%;
      place-items: center;
      color: rgba(255, 255, 255, .88);
      font-size: 25px;
      font-weight: 800;
    }

    .details {
      min-width: 0;
      padding-left: 2px;
    }

    .title-row {
      display: flex;
      max-width: 100%;
      min-width: 0;
      align-items: center;
      gap: 10px;
    }

    .title-logo {
      display: none;
      width: 30px;
      height: 30px;
      flex: 0 0 30px;
      object-fit: contain;
      border-radius: 7px;
      filter: drop-shadow(0 2px 5px rgba(0, 0, 0, .28));
    }

    .track.current.is-playing .title-logo {
      display: block;
    }

    .title, .artist {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .title {
      min-width: 0;
      flex: 1 1 auto;
      font-size: 25px;
      line-height: 1.2;
      font-weight: 800;
      letter-spacing: -.015em;
      text-shadow: 0 1px 4px rgba(0, 0, 0, .3);
    }

    .current .title { font-size: 26px; }

    .artist {
      margin-top: 5px;
      color: var(--muted);
      font-size: 19px;
      line-height: 1.2;
      font-weight: 550;
    }

    .current .artist {
      margin-top: 3px;
      font-size: 18px;
    }

    .status {
      justify-self: end;
      min-width: 102px;
      padding: 7px 14px;
      border: 1px solid color-mix(in srgb, var(--accent) 22%, transparent);
      border-radius: 8px;
      background: #263040;
      background: color-mix(in srgb, var(--accent-dark) 62%, #101722);
      color: var(--accent);
      color: color-mix(in srgb, var(--accent) 82%, white);
      font-size: 13px;
      font-weight: 850;
      letter-spacing: .035em;
      text-align: center;
    }

    .progress {
      position: relative;
      height: 7px;
      overflow: hidden;
      border-radius: 4px;
      background: rgba(255, 255, 255, .16);
      box-shadow: inset 0 1px 2px rgba(0, 0, 0, .22);
    }

    .progress > span {
      display: block;
      width: 0;
      height: 100%;
      border-radius: inherit;
      background: linear-gradient(90deg, var(--accent-dark), var(--accent));
      box-shadow: 0 0 10px color-mix(in srgb, var(--accent) 55%, transparent);
      transition: width 420ms linear;
    }

    .playback { margin-top: 9px; }

    .time-row {
      display: flex;
      justify-content: space-between;
      gap: 16px;
      margin-top: 4px;
      color: var(--muted);
      font-size: 14px;
      line-height: 1;
      font-weight: 650;
      font-variant-numeric: tabular-nums;
    }

    @media (max-width: 560px) {
      #overlay { width: calc(100vw - 24px); margin: 12px auto; }
      #queue { gap: 7px; }
      .track { border-radius: 13px; }
      .track:not(.current) { grid-template-columns: 72px minmax(0, 1fr); }
      .track.current { grid-template-columns: 92px minmax(0, 1fr); }
      .track:not(.current) .artwork { width: 62px; height: 62px; }
      .status { display: none; }
      .current .artwork { width: 78px; height: 78px; }
      .title-row { gap: 8px; }
      .title-logo { width: 24px; height: 24px; flex-basis: 24px; }
      .current .title { font-size: 21px; }
    }

    @media (prefers-reduced-motion: reduce) {
      .progress > span { transition: none; }
    }
  </style>
</head>
<body>
  <main id="overlay">
    <section id="queue" aria-live="polite"></section>
  </main>
  <script>
    (() => {
      const queue = document.getElementById('queue');
      let retry = 0;
      let socket;
      let reconnectTimer;
      let socketGeneration = 0;
      let lastLayoutSignature = '';
      const cardsByKey = new Map();
      const leavingCards = new Map();
      const reducedMotion = window.matchMedia(
        '(prefers-reduced-motion: reduce)');

      const fallbackLabels = {
        es: {
          resolving: 'BUSCANDO',
          downloading: 'CARGANDO',
          untitled: 'Sin título'
        },
        en: {
          resolving: 'SEARCHING',
          downloading: 'LOADING',
          untitled: 'Untitled'
        }
      };
      let localizedLabels = fallbackLabels.es;

      const safeLabel = (value, fallback) => {
        if (typeof value !== 'string') return fallback;
        const normalized = value.trim();
        return normalized || fallback;
      };

      const updateLocalization = state => {
        const localeValue = String(state && state.locale || '').toLowerCase();
        const locale = localeValue === 'en' ? 'en' : 'es';
        const fallbacks = fallbackLabels[locale];
        const supplied = state && state.labels &&
            typeof state.labels === 'object' ? state.labels : {};
        localizedLabels = {
          resolving: safeLabel(supplied.resolving, fallbacks.resolving),
          downloading: safeLabel(supplied.downloading, fallbacks.downloading),
          untitled: safeLabel(supplied.untitled, fallbacks.untitled)
        };
        document.documentElement.lang = locale;
      };

      const cssColor = (value, fallback) => {
        if (typeof value !== 'string') return fallback;
        return /^#[0-9a-f]{6}$/i.test(value) ? value : fallback;
      };

      const statusLabel = value => ({
        resolving: localizedLabels.resolving,
        downloading: localizedLabels.downloading
      })[String(value || '').toLowerCase()] || '';

      const formatTime = value => {
        const milliseconds = Number(value);
        const total = Number.isFinite(milliseconds)
          ? Math.max(0, Math.floor(milliseconds / 1000))
          : 0;
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        const seconds = String(total % 60).padStart(2, '0');
        return hours > 0
          ? `${hours}:${String(minutes).padStart(2, '0')}:${seconds}`
          : `${minutes}:${seconds}`;
      };

      const safeArtworkSource = value => {
        if (typeof value !== 'string') return '';
        return value.startsWith('/') || value.startsWith('data:image/')
          ? value
          : '';
      };

      const updateArtwork = (artwork, item) => {
        const source = safeArtworkSource(item.artwork);
        if (artwork.dataset.source === source) return;
        artwork.dataset.source = source;
        artwork.querySelectorAll('.pending-artwork').forEach(node => node.remove());

        if (!source) {
          artwork.replaceChildren();
          artwork.classList.add('fallback');
          return;
        }

        const image = document.createElement('img');
        image.className = 'pending-artwork';
        image.alt = '';
        image.decoding = 'async';
        image.addEventListener('load', () => {
          if (artwork.dataset.source !== source || !image.isConnected) {
            image.remove();
            return;
          }
          const previous = artwork.querySelector('img:not(.pending-artwork)');
          artwork.classList.remove('fallback');
          const finish = () => {
            if (artwork.dataset.source !== source || !image.isConnected) return;
            image.classList.remove('pending-artwork');
            artwork.replaceChildren(image);
          };
          if (reducedMotion.matches || !previous || !image.animate) {
            finish();
            return;
          }
          const incoming = image.animate(
            [{ opacity: 0 }, { opacity: 1 }],
            { duration: 220, easing: 'ease-out', fill: 'both' });
          const outgoing = previous.animate(
            [{ opacity: 1 }, { opacity: 0 }],
            { duration: 220, easing: 'ease-out', fill: 'both' });
          Promise.allSettled([incoming.finished, outgoing.finished]).then(finish);
        }, { once: true });
        image.addEventListener('error', () => {
          image.remove();
          if (!artwork.querySelector('img')) artwork.classList.add('fallback');
        }, { once: true });
        artwork.append(image);
        image.src = source;
      };

      const createPlayback = () => {
        const playback = document.createElement('div');
        playback.className = 'playback';
        const rail = document.createElement('div');
        rail.className = 'progress';
        rail.setAttribute('aria-hidden', 'true');
        rail.append(document.createElement('span'));
        const times = document.createElement('div');
        times.className = 'time-row';
        const elapsed = document.createElement('span');
        elapsed.className = 'elapsed';
        const duration = document.createElement('span');
        duration.className = 'duration';
        times.append(elapsed, duration);
        playback.append(rail, times);
        return playback;
      };

      const createCard = key => {
        const card = document.createElement('article');
        card.className = 'track';
        card.dataset.trackKey = key;
        const artwork = document.createElement('div');
        artwork.className = 'artwork fallback';
        card.append(artwork);
        const details = document.createElement('div');
        details.className = 'details';
        const titleRow = document.createElement('div');
        titleRow.className = 'title-row';
        const titleLogo = document.createElement('img');
        titleLogo.className = 'title-logo';
        titleLogo.src = '/bstream-icon.png';
        titleLogo.alt = '';
        titleLogo.draggable = false;
        titleLogo.setAttribute('aria-hidden', 'true');
        const title = document.createElement('div');
        title.className = 'title';
        const artist = document.createElement('div');
        artist.className = 'artist';
        titleRow.append(titleLogo, title);
        details.append(titleRow, artist);
        card.append(details);
        return card;
      };

      const updateCard = (card, item, index) => {
        const current = index === 0;
        const playing = current &&
          String(item.status || '').toLowerCase() === 'playing';
        card.classList.toggle('current', current);
        card.classList.toggle('is-playing', playing);
        card.style.setProperty('--index', index);
        card.dataset.trackId = String(item.id || '');

        const details = card.querySelector('.details');
        const title = details.querySelector('.title');
        const artist = details.querySelector('.artist');
        const nextTitle = String(item.title || localizedLabels.untitled);
        const nextArtist = String(item.artist || '');
        if (title.textContent !== nextTitle) title.textContent = nextTitle;
        if (artist.textContent !== nextArtist) artist.textContent = nextArtist;

        let playback = details.querySelector('.playback');
        if (current && !playback) {
          playback = createPlayback();
          details.append(playback);
        } else if (!current && playback) {
          playback.remove();
        }

        const label = current ? '' : statusLabel(item.status);
        let status = card.querySelector('.status');
        if (label) {
          card.classList.add('has-status');
          if (!status) {
            status = document.createElement('div');
            status.className = 'status';
            card.append(status);
          }
          if (status.textContent !== label) status.textContent = label;
        } else {
          card.classList.remove('has-status');
          if (status) status.remove();
        }

        updateArtwork(card.querySelector('.artwork'), item);
      };

      const keyedItems = items => {
        const counts = new Map();
        return items.map((item, index) => {
          const base = String(item.id || '').trim() || `position-${index}`;
          const occurrence = counts.get(base) || 0;
          counts.set(base, occurrence + 1);
          return {
            item,
            key: occurrence === 0 ? base : `${base}::${occurrence}`
          };
        });
      };

      const clearExitPlacement = card => {
        card.classList.remove('leaving');
        card.removeAttribute('aria-hidden');
        for (const property of [
          'position', 'left', 'top', 'width', 'height', 'minHeight',
          'margin', 'zIndex', 'pointerEvents'
        ]) card.style[property] = '';
      };

      const cancelCardAnimations = card => {
        if (typeof card.getAnimations !== 'function') return;
        card.getAnimations().forEach(animation => animation.cancel());
      };

      const stageExit = (key, card, rect, queueRect) => {
        cardsByKey.delete(key);
        leavingCards.set(key, card);
        const token = Symbol(key);
        card.exitToken = token;
        card.classList.add('leaving');
        card.setAttribute('aria-hidden', 'true');
        Object.assign(card.style, {
          position: 'absolute',
          left: `${rect.left - queueRect.left}px`,
          top: `${rect.top - queueRect.top}px`,
          width: `${rect.width}px`,
          height: `${rect.height}px`,
          minHeight: '0',
          margin: '0',
          zIndex: '3',
          pointerEvents: 'none'
        });
        const finish = () => {
          if (card.exitToken !== token) return;
          leavingCards.delete(key);
          card.remove();
        };
        if (reducedMotion.matches || !card.animate) {
          finish();
          return;
        }
        const animation = card.animate([
          { opacity: 1, transform: 'translate3d(0, 0, 0) scale(1)' },
          { opacity: 0, transform: 'translate3d(-18px, -12px, 0) scale(.975)' }
        ], {
          duration: 280,
          easing: 'cubic-bezier(.4, 0, 1, 1)',
          fill: 'forwards'
        });
        animation.finished.then(finish, finish);
      };

      const animateMove = (card, first, last) => {
        if (reducedMotion.matches || !card.animate) return;
        const deltaX = first.left - last.left;
        const deltaY = first.top - last.top;
        const scaleX = last.width > 0 ? first.width / last.width : 1;
        const scaleY = last.height > 0 ? first.height / last.height : 1;
        if (Math.abs(deltaX) < .5 && Math.abs(deltaY) < .5 &&
            Math.abs(scaleX - 1) < .005 && Math.abs(scaleY - 1) < .005) {
          return;
        }
        card.animate([
          {
            transformOrigin: 'top left',
            transform: `translate3d(${deltaX}px, ${deltaY}px, 0) ` +
              `scale(${scaleX}, ${scaleY})`
          },
          { transformOrigin: 'top left', transform: 'none' }
        ], {
          duration: 420,
          easing: 'cubic-bezier(.2, .8, .2, 1)'
        });
      };

      const animateEntry = (card, delay) => {
        if (reducedMotion.matches || !card.animate) return;
        card.animate([
          { opacity: 0, transform: 'translate3d(0, 14px, 0) scale(.988)' },
          { opacity: 1, transform: 'translate3d(0, 0, 0) scale(1)' }
        ], {
          duration: 320,
          delay,
          easing: 'cubic-bezier(.2, .8, .2, 1)',
          fill: 'backwards'
        });
      };

      const reconcileCards = items => {
        const entries = keyedItems(items);
        const layoutSignature = entries.map(entry => entry.key).join('\u001f');
        const layoutChanged = layoutSignature !== lastLayoutSignature;

        if (!layoutChanged) {
          entries.forEach((entry, index) => {
            const card = cardsByKey.get(entry.key);
            if (card) updateCard(card, entry.item, index);
          });
          return;
        }

        const initialLayout = cardsByKey.size === 0 && leavingCards.size === 0;
        const firstRects = new Map();
        for (const card of cardsByKey.values()) {
          firstRects.set(card, card.getBoundingClientRect());
        }
        const queueRect = queue.getBoundingClientRect();
        for (const card of cardsByKey.values()) {
          cancelCardAnimations(card);
        }

        const nextKeys = new Set(entries.map(entry => entry.key));
        for (const [key, card] of [...cardsByKey]) {
          if (!nextKeys.has(key)) {
            stageExit(key, card, firstRects.get(card), queueRect);
          }
        }

        const newCards = [];
        entries.forEach((entry, index) => {
          let card = cardsByKey.get(entry.key);
          if (!card) {
            card = leavingCards.get(entry.key);
            if (card) {
              const visualRect = card.getBoundingClientRect();
              card.exitToken = null;
              cancelCardAnimations(card);
              leavingCards.delete(entry.key);
              clearExitPlacement(card);
              firstRects.set(card, visualRect);
            } else {
              card = createCard(entry.key);
              newCards.push({ card, index });
            }
            cardsByKey.set(entry.key, card);
          }
          updateCard(card, entry.item, index);
          queue.append(card);
        });

        for (const card of cardsByKey.values()) {
          const first = firstRects.get(card);
          if (first) animateMove(card, first, card.getBoundingClientRect());
        }
        for (const entry of newCards) {
          animateEntry(entry.card, initialLayout ? entry.index * 35 : 70);
        }
        lastLayoutSignature = layoutSignature;
      };

      const render = (state) => {
        updateLocalization(state);
        const accent = state && state.accent ? state.accent : {};
        document.documentElement.style.setProperty(
          '--accent', cssColor(accent.seed, '#f5f7f5'));
        document.documentElement.style.setProperty(
          '--accent-dark', cssColor(accent.dark, '#59615c'));

        const items = Array.isArray(state && state.items)
          ? state.items.slice(0, 5)
          : [];
        const progress = Math.max(0, Math.min(1, Number(state && state.progress) || 0));
        const durationMs = Math.max(0, Number(state && state.durationMs) || 0);
        const positionMs = Math.max(0, Math.min(
          Number(state && state.positionMs) || 0,
          durationMs > 0 ? durationMs : Number.MAX_SAFE_INTEGER
        ));

        reconcileCards(items);

        const fill = queue.querySelector(
          '.track.current:not(.leaving) .progress > span');
        if (fill) fill.style.width = `${(progress * 100).toFixed(2)}%`;
        const elapsed = queue.querySelector(
          '.track.current:not(.leaving) .elapsed');
        if (elapsed) elapsed.textContent = formatTime(positionMs);
        const duration = queue.querySelector(
          '.track.current:not(.leaving) .duration');
        if (duration) {
          duration.textContent = durationMs > 0 ? formatTime(durationMs) : '--:--';
        }
      };

      const connect = () => {
        clearTimeout(reconnectTimer);
        const generation = ++socketGeneration;
        const nextSocket = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
        socket = nextSocket;
        nextSocket.addEventListener('open', () => {
          if (generation === socketGeneration) retry = 0;
        });
        nextSocket.addEventListener('message', event => {
          if (generation !== socketGeneration) return;
          try { render(JSON.parse(event.data)); } catch (_) {}
        });
        nextSocket.addEventListener('close', () => {
          if (generation !== socketGeneration) return;
          const delay = Math.min(5000, 350 * (2 ** Math.min(retry++, 4)));
          reconnectTimer = setTimeout(connect, delay);
        });
        nextSocket.addEventListener('error', () => nextSocket.close());
      };

      connect();
    })();
  </script>
</body>
</html>
''';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/features/music/presentation/services/live_overlay_document.dart';
import 'package:bstream_music/services/live/local_overlay_hosts.dart';
import 'package:bstream_music/services/live/local_overlay_server.dart';

/// Starts the real loopback-only HTTP/WS overlay with sample queue data.
///
/// This is intentionally independent from Flutter's UI so the Windows overlay
/// can be styled and captured in LIVE Studio directly from source code:
///
///   dart run tool/live_overlay_preview.dart
Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('La vista previa local de la overlay requiere Windows.');
    exitCode = 1;
    return;
  }

  final previewState = _previewState();
  final server = LocalLiveOverlayServer(
    hostProvisioner: WindowsLocalOverlayHostProvisioner(),
    htmlDocument: liveOverlayHtml.replaceFirst(
      '      connect();',
      '      window.__bstreamPreviewRender = render;\n'
          '      render(${jsonEncode(previewState)});\n'
          '      connect();',
    ),
    brandIconBytes: await File('assets/icons/bstream_icon.png').readAsBytes(),
  );
  StreamSubscription<ProcessSignal>? signalSubscription;
  StreamSubscription<String>? inputSubscription;

  try {
    final uri = await server.start();
    server.publishJson(previewState);

    stdout
      ..writeln('Overlay LIVE de prueba activa en $uri')
      ..writeln(
        'Añade esa URL como fuente web de '
        '$liveOverlayCanvasWidth × $liveOverlayCanvasHeight.',
      )
      ..writeln('Presiona Enter o Ctrl+C para detenerla.');

    final stopped = Completer<void>();
    signalSubscription = ProcessSignal.sigint.watch().listen((_) {
      if (!stopped.isCompleted) stopped.complete();
    });
    inputSubscription = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (_) {
            if (!stopped.isCompleted) stopped.complete();
          },
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        );
    await stopped.future;
  } finally {
    await signalSubscription?.cancel();
    await inputSubscription?.cancel();
    await server.stop();
  }
}

Map<String, Object> _previewState() => <String, Object>{
  'type': 'state',
  'version': 1,
  'locale': 'es',
  'labels': <String, String>{
    'resolving': 'BUSCANDO',
    'downloading': 'CARGANDO',
    'untitled': 'Sin título',
  },
  'accent': <String, String>{'seed': '#43A7FF', 'dark': '#155B9B'},
  'progress': 0.38,
  'positionMs': 93000,
  'durationMs': 244000,
  'items': <Map<String, Object>>[
    _sampleTrack(
      1,
      'Más De La Una',
      'Piso 21, Maluma',
      'playing',
      '#F59E0B',
      '#7C2D12',
    ),
    _sampleTrack(
      2,
      'Te Amo',
      'Piso 21, Paulo Londra',
      'ready',
      '#A855F7',
      '#312E81',
    ),
    _sampleTrack(3, 'Este Adiós', 'Los Bukis', 'ready', '#22C55E', '#14532D'),
    _sampleTrack(
      4,
      'Crucé de Amor',
      'Son By Four',
      'downloading',
      '#F43F5E',
      '#881337',
    ),
    _sampleTrack(
      5,
      'Perfecta',
      'Miranda!, Julieta Venegas',
      'resolving',
      '#06B6D4',
      '#164E63',
    ),
  ],
};

Map<String, Object> _sampleTrack(
  int number,
  String title,
  String artist,
  String status,
  String colorA,
  String colorB,
) {
  final svg =
      '''
<svg xmlns="http://www.w3.org/2000/svg" width="192" height="192" viewBox="0 0 192 192">
  <defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="$colorA"/><stop offset="1" stop-color="$colorB"/></linearGradient></defs>
  <rect width="192" height="192" rx="28" fill="url(#g)"/>
  <circle cx="96" cy="96" r="55" fill="none" stroke="white" stroke-opacity=".36" stroke-width="6"/>
  <text x="96" y="115" text-anchor="middle" font-family="Segoe UI, sans-serif" font-size="58" font-weight="800" fill="white">$number</text>
</svg>''';
  return <String, Object>{
    'id': 'preview-$number',
    'title': title,
    'artist': artist,
    'status': status,
    'artwork': Uri.dataFromString(
      svg,
      mimeType: 'image/svg+xml',
      encoding: utf8,
    ).toString(),
  };
}

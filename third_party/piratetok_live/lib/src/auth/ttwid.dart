import 'dart:async';
import 'dart:io';

import '../cancellation.dart';
import '../http/ua.dart';

/// Fetch a fresh ttwid cookie via anonymous GET to tiktok.com.
Future<String> fetchTtwid({
  Duration timeout = const Duration(seconds: 10),
  String proxy = '',
  String? userAgent,
  CancellationToken? cancellationToken,
}) async {
  final ua = userAgent ?? randomUa();
  final client = HttpClient();
  StreamSubscription<void>? cancellationSubscription;
  try {
    if (proxy.isNotEmpty) {
      final proxyUri = Uri.parse(proxy);
      client.findProxy = (_) => 'PROXY ${proxyUri.host}:${proxyUri.port}';
    }
    client.connectionTimeout = timeout;
    client.userAgent = ua;
    if (cancellationToken != null) {
      if (cancellationToken.isCancelled) {
        throw const HttpException('TikTok request cancelled.');
      }
      cancellationSubscription = cancellationToken.onCancel.listen((_) {
        client.close(force: true);
      });
      if (cancellationToken.isCancelled) {
        throw const HttpException('TikTok request cancelled.');
      }
    }

    final request = await client
        .getUrl(Uri.parse('https://www.tiktok.com/'))
        .timeout(timeout);
    request.followRedirects = true;
    final response = await request.close().timeout(timeout);
    // Drain the response body
    await response.drain<void>().timeout(timeout);

    for (final cookie in response.cookies) {
      if (cookie.name == 'ttwid') return cookie.value;
    }

    throw StateError('ttwid: no ttwid cookie in response');
  } finally {
    await cancellationSubscription?.cancel();
    client.close(force: true);
  }
}

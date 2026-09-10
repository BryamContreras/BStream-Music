import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../cancellation.dart';
import '../http/ua.dart';

const _registrationPayload = <String, Object>{
  'aid': 1988,
  'service': 'www.tiktok.com',
  'union': false,
  'unionHost': '',
  'needFid': false,
  'fid': '',
  'migrate_priority': 0,
};

/// Fetch a fresh anonymous TikTok device cookie.
///
/// TikTok no longer consistently issues `ttwid` from its homepage. Prefer the
/// dedicated registration route, then fall back to pages that currently issue
/// the same cookie. [registrationUri] and [bootstrapUris] exist so the network
/// contract can be exercised against a local HTTP server in tests.
Future<String> fetchTtwid({
  Duration timeout = const Duration(seconds: 10),
  String proxy = '',
  String? userAgent,
  String? username,
  String? language,
  String? region,
  CancellationToken? cancellationToken,
  Uri? registrationUri,
  List<Uri>? bootstrapUris,
}) async {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'must be positive');
  }
  final ua = userAgent ?? randomUa();
  final lang = language ?? systemLanguage();
  final reg = region ?? systemRegion();
  final clean = username?.trim().replaceFirst(RegExp(r'^@'), '') ?? '';
  final register =
      registrationUri ?? Uri.parse('https://www.tiktok.com/ttwid/register/');
  final pages =
      bootstrapUris ??
      <Uri>[
        if (clean.isNotEmpty)
          Uri.parse(
            'https://www.tiktok.com/@${Uri.encodeComponent(clean)}/live',
          ),
        Uri.parse('https://www.tiktok.com/live'),
        // Kept as a last fallback for regions where the homepage still issues
        // the anonymous device cookie.
        Uri.parse('https://www.tiktok.com/'),
      ];
  final client = HttpClient();
  StreamSubscription<void>? cancellationSubscription;
  final elapsed = Stopwatch()..start();
  Object? lastError;
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

    try {
      final request = await client
          .postUrl(register)
          .timeout(_remaining(timeout, elapsed));
      _setBrowserHeaders(request, ua: ua, language: lang, region: reg);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.contentType = ContentType.json;
      request.headers.set('Origin', 'https://www.tiktok.com');
      request.headers.set(HttpHeaders.refererHeader, 'https://www.tiktok.com/');
      request.write(jsonEncode(_registrationPayload));
      final cookie = await _closeAndReadTtwid(
        request,
        timeout: _remaining(timeout, elapsed),
      );
      if (cookie != null) return cookie;
    } on Object catch (error) {
      if (cancellationToken?.isCancelled ?? false) {
        throw const HttpException('TikTok request cancelled.');
      }
      lastError = error;
    }

    for (final uri in pages) {
      try {
        if (cancellationToken?.isCancelled ?? false) {
          throw const HttpException('TikTok request cancelled.');
        }
        final request = await client
            .getUrl(uri)
            .timeout(_remaining(timeout, elapsed));
        request.followRedirects = true;
        _setBrowserHeaders(request, ua: ua, language: lang, region: reg);
        final cookie = await _closeAndReadTtwid(
          request,
          timeout: _remaining(timeout, elapsed),
        );
        if (cookie != null) return cookie;
      } on Object catch (error) {
        if (cancellationToken?.isCancelled ?? false) {
          throw const HttpException('TikTok request cancelled.');
        }
        lastError = error;
      }
    }

    final detail = lastError == null ? '' : ' Last error: $lastError';
    throw StateError(
      'ttwid: TikTok did not issue a usable anonymous device cookie.$detail',
    );
  } finally {
    elapsed.stop();
    await cancellationSubscription?.cancel();
    client.close(force: true);
  }
}

void _setBrowserHeaders(
  HttpClientRequest request, {
  required String ua,
  required String language,
  required String region,
}) {
  request.headers.set(HttpHeaders.userAgentHeader, ua);
  request.headers.set(
    HttpHeaders.acceptLanguageHeader,
    '$language-$region,$language;q=0.9',
  );
}

Future<String?> _closeAndReadTtwid(
  HttpClientRequest request, {
  required Duration timeout,
}) async {
  final response = await request.close().timeout(timeout);
  final cookie = response.cookies
      .where((candidate) => candidate.name == 'ttwid')
      .map((candidate) => candidate.value)
      .where(_isUsableTtwid)
      .firstOrNull;
  await response.drain<void>().timeout(timeout);
  return cookie;
}

bool _isUsableTtwid(String value) {
  final trimmed = value.trim();
  return trimmed.length >= 16 &&
      !trimmed.contains(';') &&
      !RegExp(r'[\x00-\x20\x7f]').hasMatch(trimmed);
}

Duration _remaining(Duration timeout, Stopwatch elapsed) {
  final value = timeout - elapsed.elapsed;
  if (value <= Duration.zero) {
    throw TimeoutException('Timed out while obtaining TikTok ttwid.', timeout);
  }
  return value;
}

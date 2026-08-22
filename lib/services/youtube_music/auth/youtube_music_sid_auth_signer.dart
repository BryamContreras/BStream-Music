import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'youtube_music_cookie_codec.dart';

typedef YouTubeMusicClock = DateTime Function();

/// Produces the SID proof format expected by the YouTube web client.
///
/// SHA-1 is part of the remote protocol here; it is not used to store or hash
/// a password.
class YouTubeMusicSidAuthSigner {
  YouTubeMusicSidAuthSigner({
    YouTubeMusicClock? clock,
    this.origin = 'https://music.youtube.com',
    this.cookieCodec = const YouTubeMusicCookieCodec(),
  }) : _clock = clock ?? DateTime.now;

  final YouTubeMusicClock _clock;
  final String origin;
  final YouTubeMusicCookieCodec cookieCodec;

  String sign(String cookieHeader) {
    final cookies = cookieCodec.decode(cookieHeader);
    final timestamp = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    final proofs = <String>[];
    _appendProof(
      proofs,
      scheme: 'SAPISIDHASH',
      secret: cookies['SAPISID'] ?? cookies['__Secure-3PAPISID'],
      timestamp: timestamp,
    );
    _appendProof(
      proofs,
      scheme: 'SAPISID1PHASH',
      secret: cookies['__Secure-1PAPISID'],
      timestamp: timestamp,
    );
    _appendProof(
      proofs,
      scheme: 'SAPISID3PHASH',
      secret: cookies['__Secure-3PAPISID'],
      timestamp: timestamp,
    );
    if (proofs.isEmpty) {
      throw const FormatException('Missing YouTube Music session cookie.');
    }
    return proofs.join(' ');
  }

  void _appendProof(
    List<String> proofs, {
    required String scheme,
    required String? secret,
    required int timestamp,
  }) {
    if (secret == null || secret.isEmpty) return;
    final input = '$timestamp $secret $origin';
    final digest = sha1.convert(utf8.encode(input));
    proofs.add('$scheme ${timestamp}_$digest');
  }
}

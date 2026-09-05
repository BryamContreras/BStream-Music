import 'dart:convert';
import 'dart:io';

typedef GitHubLatestReleaseFetcher =
    Future<Map<String, Object?>> Function(Uri endpoint);

class AppReleaseCheckResult {
  const AppReleaseCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseTag,
  });

  final String currentVersion;
  final String latestVersion;
  final String releaseTag;

  bool get updateAvailable =>
      compareAppVersions(latestVersion, currentVersion) > 0;
}

class GitHubReleaseChecker {
  GitHubReleaseChecker({
    this.repository = 'BryamContreras/BStream-Music',
    GitHubLatestReleaseFetcher? fetchLatestRelease,
  }) : _fetchLatestRelease = fetchLatestRelease ?? _fetchFromGitHub;

  final String repository;
  final GitHubLatestReleaseFetcher _fetchLatestRelease;

  Uri get latestReleaseEndpoint =>
      Uri.https('api.github.com', '/repos/$repository/releases/latest');

  Future<AppReleaseCheckResult> check({required String currentVersion}) async {
    final payload = await _fetchLatestRelease(latestReleaseEndpoint);
    final rawTag = payload['tag_name'];
    if (rawTag is! String || rawTag.trim().isEmpty) {
      throw const FormatException(
        'The latest GitHub release does not contain a tag name.',
      );
    }
    final tag = rawTag.trim();
    final latestVersion = _AppVersion.parse(tag).normalized;
    final normalizedCurrent = _AppVersion.parse(currentVersion).normalized;
    return AppReleaseCheckResult(
      currentVersion: normalizedCurrent,
      latestVersion: latestVersion,
      releaseTag: tag,
    );
  }

  static Future<Map<String, Object?>> _fetchFromGitHub(Uri endpoint) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(endpoint)
          .timeout(const Duration(seconds: 10));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'BStream-Music-update-check')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          'GitHub latest release request failed (${response.statusCode}).',
          uri: endpoint,
        );
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException(
          'The latest GitHub release response is not an object.',
        );
      }
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value as Object?),
      );
    } finally {
      client.close(force: true);
    }
  }
}

int compareAppVersions(String left, String right) {
  return _AppVersion.parse(left).compareTo(_AppVersion.parse(right));
}

class _AppVersion implements Comparable<_AppVersion> {
  const _AppVersion(this.numbers, this.preRelease);

  static final RegExp _pattern = RegExp(
    r'^v?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    caseSensitive: false,
  );

  final List<int> numbers;
  final List<String> preRelease;

  String get normalized {
    final base = numbers.join('.');
    return preRelease.isEmpty ? base : '$base-${preRelease.join('.')}';
  }

  static _AppVersion parse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Invalid app version: $value');
    }
    return _AppVersion(
      match.group(1)!.split('.').map(int.parse).toList(growable: false),
      match.group(2)?.split('.') ?? const <String>[],
    );
  }

  @override
  int compareTo(_AppVersion other) {
    final partCount = numbers.length > other.numbers.length
        ? numbers.length
        : other.numbers.length;
    for (var index = 0; index < partCount; index += 1) {
      final left = index < numbers.length ? numbers[index] : 0;
      final right = index < other.numbers.length ? other.numbers[index] : 0;
      if (left != right) {
        return left.compareTo(right);
      }
    }
    if (preRelease.isEmpty || other.preRelease.isEmpty) {
      if (preRelease.isEmpty == other.preRelease.isEmpty) {
        return 0;
      }
      return preRelease.isEmpty ? 1 : -1;
    }
    final identifierCount = preRelease.length > other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var index = 0; index < identifierCount; index += 1) {
      if (index >= preRelease.length) return -1;
      if (index >= other.preRelease.length) return 1;
      final comparison = _comparePreReleaseIdentifier(
        preRelease[index],
        other.preRelease[index],
      );
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static int _comparePreReleaseIdentifier(String left, String right) {
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    if (leftNumber != null && rightNumber != null) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null) return -1;
    if (rightNumber != null) return 1;
    return left.compareTo(right);
  }
}

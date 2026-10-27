import 'package:bstream_music/services/app_update/github_release_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'checks the repository latest release and detects a newer version',
    () async {
      Uri? requestedEndpoint;
      final checker = GitHubReleaseChecker(
        fetchLatestRelease: (endpoint) async {
          requestedEndpoint = endpoint;
          return <String, Object?>{
            'tag_name': 'v1.3.0',
            'body': '  - Better playback.\n- New widgets.\u0000  ',
          };
        },
      );

      final result = await checker.check(currentVersion: '1.2.6');

      expect(
        requestedEndpoint,
        Uri.parse(
          'https://api.github.com/repos/BryamContreras/BStream-Music/releases/latest',
        ),
      );
      expect(result.currentVersion, '1.2.6');
      expect(result.latestVersion, '1.3.0');
      expect(result.releaseTag, 'v1.3.0');
      expect(result.releaseNotes, '- Better playback.\n- New widgets.');
      expect(result.updateAvailable, isTrue);
    },
  );

  test('does not report an older GitHub release as an update', () async {
    final checker = GitHubReleaseChecker(
      fetchLatestRelease: (_) async => <String, Object?>{'tag_name': 'v1.2.5'},
    );

    final result = await checker.check(currentVersion: '1.2.6');

    expect(result.updateAvailable, isFalse);
    expect(result.releaseNotes, isEmpty);
  });

  for (final body in [null, 42, <String, Object?>{}]) {
    test('ignores a missing or malformed release body ($body)', () async {
      final checker = GitHubReleaseChecker(
        fetchLatestRelease: (_) async => {'tag_name': 'v1.3.0', 'body': body},
      );

      final result = await checker.check(currentVersion: '1.2.9');

      expect(result.updateAvailable, isTrue);
      expect(result.releaseNotes, isEmpty);
    });
  }

  test('compares semantic versions instead of comparing their text', () {
    expect(compareAppVersions('v1.10.0', '1.9.9'), greaterThan(0));
    expect(compareAppVersions('2.0.0', '2.0.0-rc.1'), greaterThan(0));
    expect(compareAppVersions('1.2.6+130', '1.2.6+126'), 0);
    expect(compareAppVersions('1.2', '1.2.0'), 0);
  });

  test('rejects a latest release without a valid version tag', () async {
    final checker = GitHubReleaseChecker(
      fetchLatestRelease: (_) async => <String, Object?>{'tag_name': 'latest'},
    );

    await expectLater(
      checker.check(currentVersion: '1.2.6'),
      throwsA(isA<FormatException>()),
    );
  });
}

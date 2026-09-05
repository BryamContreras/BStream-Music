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
          return <String, Object?>{'tag_name': 'v1.3.0'};
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
      expect(result.updateAvailable, isTrue);
    },
  );

  test('does not report an older GitHub release as an update', () async {
    final checker = GitHubReleaseChecker(
      fetchLatestRelease: (_) async => <String, Object?>{'tag_name': 'v1.2.5'},
    );

    final result = await checker.check(currentVersion: '1.2.6');

    expect(result.updateAvailable, isFalse);
  });

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

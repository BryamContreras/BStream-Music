import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release metadata exposes the same version and build number', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final readme = File('README.md').readAsStringSync();
    final changelog = File('CHANGELOG.md').readAsStringSync();
    final windowsInstaller = File(
      'packaging/windows/BStreamMusic.iss',
    ).readAsStringSync();
    final pubspecVersion = RegExp(
      r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    final readmeVersion = RegExp(
      r'Current version:\s*\*\*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\*\*',
    ).firstMatch(readme)?.group(1);
    final changelogVersion = RegExp(
      r'^##\s+([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\s+',
      multiLine: true,
    ).firstMatch(changelog)?.group(1);
    final runtimeVersion = pubspecVersion?.split('+').first;
    final installerVersion = RegExp(
      r'#define MyAppVersion "([0-9]+\.[0-9]+\.[0-9]+)"',
    ).firstMatch(windowsInstaller)?.group(1);

    expect(pubspecVersion, '1.2.6+126');
    expect(readmeVersion, pubspecVersion);
    expect(changelogVersion, pubspecVersion);
    expect(runtimeVersion, AppConstants.appVersion);
    expect(installerVersion, AppConstants.appVersion);
    expect(windowsInstaller, contains('AppVersion={#MyAppVersion}'));
    expect(
      windowsInstaller,
      contains('AppVerName={#MyAppName} {#MyAppVersion}'),
    );
  });

  test('uses the requested search size and official project URLs', () {
    expect(AppConstants.defaultSearchLimit, 20);
    expect(
      AppConstants.supportDevelopmentUrl,
      'https://ko-fi.com/soybryam06c/donate',
    );
    expect(
      AppConstants.githubRepositoryUrl,
      'https://github.com/BryamContreras/BStream-Music',
    );
  });

  test('uses only the in-process Dart YouTube resolver architecture', () {
    final pubspec = File('pubspec.yaml').readAsStringSync().toLowerCase();
    final lockfile = File('pubspec.lock').readAsStringSync().toLowerCase();
    final nightlyWorkflow = File(
      '.github/workflows/nightly-smoke.yml',
    ).readAsStringSync();

    expect(pubspec, isNot(contains('youtube_explode_dart')));
    expect(lockfile, isNot(contains('youtube_explode_dart')));
    expect(pubspec, isNot(contains('yt-dlp')));
    expect(lockfile, isNot(contains('yt-dlp')));
    expect(
      nightlyWorkflow,
      contains('integration_test/innertube_playback_live_test.dart'),
    );
    expect(
      nightlyWorkflow,
      contains('--dart-define=BSTREAM_LIVE_INNERTUBE=true'),
    );
    expect(
      nightlyWorkflow,
      isNot(contains('youtube_explode_playback_test.dart')),
    );
  });
}

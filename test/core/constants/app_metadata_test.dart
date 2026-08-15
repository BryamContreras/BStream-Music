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

    expect(pubspecVersion, '1.2.4+124');
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

  test('uses the requested search size and support URL', () {
    expect(AppConstants.defaultSearchLimit, 20);
    expect(
      AppConstants.supportDevelopmentUrl,
      'https://ko-fi.com/soybryam06c/donate',
    );
  });
}

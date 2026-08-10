import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pubspec, runtime constants, and README expose the same version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final readme = File('README.md').readAsStringSync();
    final pubspecVersion = RegExp(
      r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    final readmeVersion = RegExp(
      r'Current version:\s*\*\*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+\*\*',
    ).firstMatch(readme)?.group(1);

    expect(pubspecVersion, AppConstants.appVersion);
    expect(readmeVersion, AppConstants.appVersion);
  });

  test('uses the requested search size and support URL', () {
    expect(AppConstants.defaultSearchLimit, 15);
    expect(
      AppConstants.supportDevelopmentUrl,
      'https://ko-fi.com/soybryam06c/donate',
    );
  });
}

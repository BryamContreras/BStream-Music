import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Windows package declares its OS, architecture, and elevation contract',
    () {
      final installer = File(
        'packaging/windows/BStreamMusic.iss',
      ).readAsStringSync();
      final manifest = File(
        'windows/runner/runner.exe.manifest',
      ).readAsStringSync();

      expect(
        installer,
        contains(RegExp(r'^MinVersion=10\.0\s*$', multiLine: true)),
      );
      expect(
        installer,
        contains(RegExp(r'^PrivilegesRequired=lowest\s*$', multiLine: true)),
      );
      expect(
        installer,
        contains(
          RegExp(r'^ArchitecturesAllowed=x64compatible\s*$', multiLine: true),
        ),
      );
      expect(
        installer,
        contains(
          RegExp(
            r'^ArchitecturesInstallIn64BitMode=x64compatible\s*$',
            multiLine: true,
          ),
        ),
      );
      expect(
        manifest,
        contains(
          '<requestedExecutionLevel level="asInvoker" uiAccess="false"/>',
        ),
      );
      expect(manifest, contains('Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"'));
    },
  );

  test('Windows LIVE overlay support boundaries remain documented', () {
    final compatibility = File(
      'docs/windows_live_overlay_compatibility.md',
    ).readAsStringSync();

    for (final expectedBoundary in <String>[
      'Windows 11 x64 | Supported',
      'Windows 10 22H2 x64 | Legacy compatibility',
      'Windows 11 ARM64 | Experimental',
      'Windows 10 x86 | Not supported',
      'Windows 10 ARM64 | Not supported',
      'Windows in S mode | Not supported',
      'TCP port `80`',
      'proxy auto-configuration',
    ]) {
      expect(compatibility, contains(expectedBoundary));
    }
  });
}

import 'dart:io';

import 'package:path/path.dart' as p;

/// Finds a bundled desktop executable without depending on the shell PATH.
String? findBundledDenoExecutable({List<Directory>? directoryOverrides}) {
  final names = Platform.isWindows
      ? const ['deno.exe', 'deno']
      : const ['deno'];
  final directories = desktopToolDirectories(overrides: directoryOverrides);
  for (final directory in directories) {
    for (final name in names) {
      final candidate = File(p.join(directory.path, name));
      if (candidate.existsSync() &&
          candidate.statSync().type == FileSystemEntityType.file) {
        return candidate.path;
      }
    }
  }
  return null;
}

List<Directory> desktopToolDirectories({List<Directory>? overrides}) {
  if (overrides != null) {
    return List.unmodifiable(overrides);
  }

  final executableDirectory = File(Platform.resolvedExecutable).parent;
  final currentDirectory = Directory.current;
  final directories = <Directory>[
    Directory(p.join(executableDirectory.path, 'tools')),
    Directory(p.join(executableDirectory.parent.path, 'Resources', 'tools')),
    Directory(p.join(currentDirectory.path, 'linux', 'tools')),
    Directory(p.join(currentDirectory.path, 'macos', 'tools')),
    Directory(p.join(currentDirectory.path, 'windows', 'tools')),
    Directory(p.join(currentDirectory.path, 'tools')),
  ];

  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    directories.add(
      Directory('/Applications/BStream Music.app/Contents/Resources/tools'),
    );
    if (home != null && home.isNotEmpty) {
      directories.add(
        Directory(
          p.join(
            home,
            'Applications',
            'BStream Music.app',
            'Contents',
            'Resources',
            'tools',
          ),
        ),
      );
    }
  }

  var cursor = executableDirectory;
  for (var index = 0; index < 8; index++) {
    directories.add(Directory(p.join(cursor.path, 'linux', 'tools')));
    directories.add(Directory(p.join(cursor.path, 'macos', 'tools')));
    directories.add(Directory(p.join(cursor.path, 'windows', 'tools')));
    final parent = cursor.parent;
    if (parent.path == cursor.path) {
      break;
    }
    cursor = parent;
  }

  final unique = <String, Directory>{};
  for (final directory in directories) {
    unique[p.normalize(directory.path)] = directory;
  }
  return unique.values.toList(growable: false);
}

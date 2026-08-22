import 'dart:io';

double? parseSizeBudgetMiB(String value) {
  final parsed = double.tryParse(value);
  if (parsed == null || !parsed.isFinite || parsed <= 0) {
    return null;
  }
  return parsed;
}

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/check_artifact_size.dart <artifact> <max-mib>',
    );
    exitCode = 64;
    return;
  }

  final artifact = File(arguments[0]);
  final maximumMiB = parseSizeBudgetMiB(arguments[1]);
  if (maximumMiB == null) {
    stderr.writeln('Invalid size budget: ${arguments[1]}');
    exitCode = 64;
    return;
  }
  if (!artifact.existsSync()) {
    stderr.writeln('Artifact does not exist: ${artifact.path}');
    exitCode = 66;
    return;
  }

  const bytesPerMiB = 1024 * 1024;
  final bytes = artifact.lengthSync();
  final actualMiB = bytes / bytesPerMiB;
  stdout.writeln(
    '${artifact.path}: ${actualMiB.toStringAsFixed(2)} MiB '
    '(budget ${maximumMiB.toStringAsFixed(2)} MiB)',
  );
  if (actualMiB > maximumMiB) {
    stderr.writeln('Artifact size budget exceeded.');
    exitCode = 1;
  }
}

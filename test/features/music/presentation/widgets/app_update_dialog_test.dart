import 'dart:async';

import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:bstream_music/features/music/presentation/providers/app_update_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/app_update_dialog.dart';
import 'package:bstream_music/services/app_update/github_release_checker.dart';
import 'package:bstream_music/services/app_update/release_notes_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _dialog = ValueKey('settings-update-available-dialog');
const _close = ValueKey('settings-update-available-close');
const _download = ValueKey('settings-update-available-download');
const _open = ValueKey('open-update');
const _release = AppReleaseCheckResult(
  currentVersion: '1.2.9',
  latestVersion: '1.3.0',
  releaseTag: 'v1.3.0',
  releaseNotes: '- Smoother scrolling.\n- New player style.',
);

void main() {
  testWidgets('shows versions and original notes while translating on demand', (
    tester,
  ) async {
    final completion = Completer<LocalizedReleaseNotes>();
    final service = _NotesService((_) => completion.future);
    await _openDialog(tester, service: service);

    expect(find.text('Nueva versión disponible'), findsOneWidget);
    expect(
      find.text('BStream Music 1.3.0 está disponible. Versión actual: 1.2.9.'),
      findsOneWidget,
    );
    expect(find.text('Novedades 1.3.0'), findsOneWidget);
    expect(find.text('Smoother scrolling.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-release-notes-loading')),
      findsOneWidget,
    );
    expect(service.languages, ['es']);

    completion.complete(
      const LocalizedReleaseNotes(
        items: ['Desplazamiento más fluido.', 'Nuevo estilo del reproductor.'],
        translated: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Desplazamiento más fluido.'), findsOneWidget);
    expect(find.text('Smoother scrolling.'), findsNothing);
    expect(
      find.byKey(const ValueKey('update-release-notes-loading')),
      findsNothing,
    );
    expect(service.languages, ['es']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download and close stay usable while translation is pending', (
    tester,
  ) async {
    final completion = Completer<LocalizedReleaseNotes>();
    final service = _NotesService((_) => completion.future);
    var downloads = 0;
    await _openDialog(
      tester,
      service: service,
      onDownload: () async => downloads++,
    );
    await tester.tap(find.byKey(_download));
    await tester.pumpAndSettle();
    expect(downloads, 1);
    expect(find.byKey(_dialog), findsNothing);
    expect(service.wasDisposed, isTrue);

    // A late response must not update a disposed dialog or leave a barrier.
    completion.complete(const LocalizedReleaseNotes(items: ['Late response']));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_open));
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsOneWidget);
    await tester.tap(find.byKey(_close));
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsNothing);
    expect(downloads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed translation keeps originals and supports retry', (
    tester,
  ) async {
    var calls = 0;
    final service = _NotesService((_) async {
      if (calls++ == 0) throw StateError('offline');
      return const LocalizedReleaseNotes(items: ['Desplazamiento más fluido.']);
    });
    await _openDialog(tester, service: service);
    await tester.pumpAndSettle();
    expect(find.text('Smoother scrolling.'), findsOneWidget);
    expect(
      find.text(
        const AppStrings(
          AppLanguage.spanish,
        ).updateReleaseNotesTranslationFailed,
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('update-release-notes-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Desplazamiento más fluido.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-release-notes-retry')),
      findsNothing,
    );
    expect(calls, 2);
  });

  testWidgets('barrier dismissal removes the modal and leaves the app usable', (
    tester,
  ) async {
    final service = _NotesService(
      (_) async => const LocalizedReleaseNotes(items: ['Improved scrolling.']),
    );
    await _openDialog(tester, service: service);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsNothing);
    await tester.tap(find.byKey(_open));
    await tester.pumpAndSettle();
    expect(find.byKey(_dialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final language in AppLanguage.values) {
    testWidgets('uses selected app language ${language.code}', (tester) async {
      final service = _NotesService(
        (_) async =>
            const LocalizedReleaseNotes(items: ['Localized release note']),
      );
      await _openDialog(tester, service: service, language: language);
      await tester.pumpAndSettle();
      expect(service.languages, [language.code]);
      expect(
        find.text(AppStrings(language).updateAvailableTitle),
        findsOneWidget,
      );
      expect(
        find.text(AppStrings(language).updateReleaseNotesTitle('1.3.0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(320, 568),
    const Size(640, 320),
    const Size(1440, 900),
  ]) {
    testWidgets('long notes scroll without overflow at $size', (tester) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });
      final service = _NotesService(
        (_) async => LocalizedReleaseNotes(
          items: List.generate(
            50,
            (index) =>
                'Mejora $index con una descripción suficientemente larga para ocupar varias líneas.',
          ),
        ),
      );
      await _openDialog(tester, service: service, textScale: 1.4);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final contentSize = tester.getSize(
        find.byKey(const ValueKey('update-release-notes-content')),
      );
      expect(contentSize.width, lessThanOrEqualTo(560));
      final downloadRect = tester.getRect(find.byKey(_download));
      expect(downloadRect.bottom, lessThanOrEqualTo(size.height));
      expect(downloadRect.left, greaterThanOrEqualTo(0));
      await tester.drag(
        find
            .descendant(
              of: find.byKey(_dialog),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
        const Offset(0, -5000),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_close));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a release without notes still offers the update actions', (
    tester,
  ) async {
    final service = _NotesService(
      (_) async => const LocalizedReleaseNotes(items: []),
    );
    await _openDialog(
      tester,
      service: service,
      release: const AppReleaseCheckResult(
        currentVersion: '1.2.9',
        latestVersion: '1.3.0',
        releaseTag: 'v1.3.0',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(const AppStrings(AppLanguage.spanish).updateReleaseNotesEmpty),
      findsOneWidget,
    );
    expect(find.byKey(_download), findsOneWidget);
    expect(
      find.byKey(const ValueKey('update-release-notes-loading')),
      findsNothing,
    );
  });
}

Future<void> _openDialog(
  WidgetTester tester, {
  required _NotesService service,
  AppLanguage language = AppLanguage.spanish,
  AppReleaseCheckResult release = _release,
  Future<void> Function()? onDownload,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appReleaseNotesServiceProvider.overrideWith((ref) {
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _open,
              onPressed: () => showAppUpdateAvailableDialog(
                context: context,
                strings: AppStrings(language),
                release: release,
                onDownload: onDownload ?? () async {},
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_open));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

class _NotesService extends ReleaseNotesService {
  _NotesService(this.result);

  final Future<LocalizedReleaseNotes> Function(String language) result;
  final languages = <String>[];
  bool wasDisposed = false;

  @override
  Future<LocalizedReleaseNotes> load(
    AppReleaseCheckResult release, {
    required String languageCode,
  }) {
    languages.add(languageCode);
    return result(languageCode);
  }

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

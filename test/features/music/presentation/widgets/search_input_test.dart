import 'package:bstream_music/features/music/presentation/widgets/search_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps the query after submitting and exposes a clear button', (
    tester,
  ) async {
    var submitted = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            hintText: 'Buscar',
            tooltip: 'Buscar',
            clearTooltip: 'Limpiar búsqueda',
            onSubmitted: (query) => submitted = query,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'camilo');
    await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
    await tester.pump();

    expect(submitted, 'camilo');
    expect(find.text('camilo'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-clear-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-clear-button')));
    await tester.pump();

    expect(find.text('camilo'), findsNothing);
    expect(find.byKey(const ValueKey('search-clear-button')), findsNothing);
  });

  testWidgets('clears the active search when text is deleted manually', (
    tester,
  ) async {
    var clearCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            hintText: 'Buscar',
            tooltip: 'Buscar',
            clearTooltip: 'Limpiar búsqueda',
            onSubmitted: (_) {},
            onCleared: () => clearCalls++,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'camilo');
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    expect(clearCalls, 1);
    expect(find.byKey(const ValueKey('search-clear-button')), findsNothing);
  });
}

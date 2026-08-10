import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('SourceImage uses its fallback for missing sources', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SourceImage(
          source: 'missing-local-artwork.jpg',
          fallback: Text('fallback'),
        ),
      ),
    );

    expect(find.text('fallback'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('ProportionalArtwork keeps its fallback for empty sources', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ProportionalArtwork(source: null, fallback: Text('fallback')),
      ),
    );

    expect(find.text('fallback'), findsOneWidget);
  });
}

/// Conservative metadata matching shared by optional animated media lookups.
/// Only presentation labels are removed; remix, live and acoustic versions stay
/// part of the identity so they cannot borrow another recording's video.
String cleanVisualTrackTitle(String title) => title
    .replaceAll(
      RegExp(
        r'\s*[\[(]\s*(?:(?:official|oficial)\s+)?(?:(?:music|musical|lyric|lyrics|letra|letras)\s+)?(?:video|audio|visualizer|lyric|lyrics|letra|letras)(?:\s+(?:official|oficial|hd|4k))?\s*[\])]',
        caseSensitive: false,
      ),
      '',
    )
    .trim();

String primaryVisualArtist(String artist) => artist
    .replaceFirst(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')
    .split(
      RegExp(
        r'(?:\s*[,;&]\s*|\s+(?:featuring|feat\.?|ft\.?|x)\s+)',
        caseSensitive: false,
      ),
    )
    .first
    .trim();

String normalVisualText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[áàâäãåā]'), 'a')
    .replaceAll(RegExp(r'[éèêëē]'), 'e')
    .replaceAll(RegExp(r'[íìîïī]'), 'i')
    .replaceAll(RegExp(r'[óòôöõō]'), 'o')
    .replaceAll(RegExp(r'[úùûüū]'), 'u')
    .replaceAll(RegExp(r'[ýÿ]'), 'y')
    .replaceAll(RegExp(r'[ñ]'), 'n')
    .replaceAll(RegExp(r'[ç]'), 'c')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

String _withoutFeaturedTitle(String title) => title.replaceFirst(
  RegExp(
    r'\s*[\[(]\s*(?:feat\.?|ft\.?|featuring|con)\s+[^\])]+[\])]\s*$',
    caseSensitive: false,
  ),
  '',
);

bool sameVisualTitle(String requested, String found) {
  final a = normalVisualText(
    _withoutFeaturedTitle(cleanVisualTrackTitle(requested)),
  );
  final b = normalVisualText(
    _withoutFeaturedTitle(cleanVisualTrackTitle(found)),
  );
  return a.isNotEmpty && a == b;
}

bool sameVisualArtist(String requested, String found) {
  final a = normalVisualText(primaryVisualArtist(requested));
  final b = normalVisualText(primaryVisualArtist(found));
  return a.isNotEmpty && a == b;
}

enum LyricsRomanizationLanguage {
  japanese('japanese'),
  korean('korean'),
  chinese('chinese'),
  cyrillic('cyrillic'),
  arabic('arabic'),
  hebrew('hebrew');

  const LyricsRomanizationLanguage(this.code);

  final String code;

  static Set<LyricsRomanizationLanguage> fromCodes(Iterable<String>? codes) {
    if (codes == null) {
      return defaultLyricsRomanizationLanguages;
    }
    final selected = values
        .where((language) => codes.contains(language.code))
        .toSet();
    return selected.isEmpty
        ? defaultLyricsRomanizationLanguages
        : Set.unmodifiable(selected);
  }
}

const defaultLyricsRomanizationLanguages = <LyricsRomanizationLanguage>{
  LyricsRomanizationLanguage.japanese,
  LyricsRomanizationLanguage.korean,
  LyricsRomanizationLanguage.chinese,
  LyricsRomanizationLanguage.cyrillic,
  LyricsRomanizationLanguage.arabic,
  LyricsRomanizationLanguage.hebrew,
};

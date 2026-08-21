import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Horizontal page margin used by all tab content.
const double appPagePaddingHorizontal = 12.0;

/// Horizontal padding applied to horizontal scrolling shelves inside sections.
const double appShelfPaddingHorizontal = 6.0;

/// Vertical spacing between a section title and the content below it.
const double appSectionTitleGap = 8.0;

/// Vertical spacing between separate sections on the same page.
const double appSectionGap = 16.0;

/// Vertical spacing between a group heading and the first card inside it.
const double appGroupHeadingGap = 10.0;

/// Vertical spacing between consecutive cards inside the same group.
const double appCardGap = 6.0;

/// Horizontal padding inside a list card's content area.
const double appListCardPaddingHorizontal = 16.0;

/// Vertical padding inside a list card's content area.
const double appListCardPaddingVertical = 12.0;

/// Minimum height of a list card row (icon + text + optional trailing).
const double appListCardMinHeight = 78.0;

/// Icon container size used inside list cards.
const double appListCardIconSize = 46.0;

/// Icon container radius used inside list cards.
const double appListCardIconRadius = 10.0;

/// Maximum width of constrained content (e.g. settings cards).
const double appContentMaxWidth = 760.0;

/// Border radius shared by all list cards across the app.
const double appCardRadius = 6.0;

/// Border radius used for bottom navigation items.
const double appNavItemRadius = 16.0;

/// Shared text style for tab header titles (Home, Biblioteca, Ajustes, etc.).
TextStyle appTabTitleStyle(BuildContext context) {
  return Theme.of(context).textTheme.headlineMedium!.copyWith(
        fontWeight: FontWeight.w900,
      );
}

/// Shared text style for section headings inside a page
/// (e.g. "Recently Played", "My Playlists", "General", "Appearance").
TextStyle appSectionTitleStyle(BuildContext context) {
  return Theme.of(context).textTheme.titleLarge!.copyWith(
        fontWeight: FontWeight.w900,
        color: AppColors.contentHeadingFor(context),
      );
}

/// Shared text style for the title text inside a list card.
TextStyle appListCardTitleStyle(BuildContext context) {
  return Theme.of(context).textTheme.titleMedium!.copyWith(
        fontWeight: FontWeight.w800,
      );
}

/// Shared text style for the subtitle text inside a list card.
TextStyle appListCardSubtitleStyle(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  return Theme.of(context).textTheme.bodySmall!.copyWith(
        color: colors.onSurfaceVariant,
        height: 1.25,
      );
}

/// Shared text style for secondary labels (e.g. "Command permissions",
/// "Pending requests" inside a settings detail page).
TextStyle appSecondaryLabelStyle(BuildContext context) {
  return Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontWeight: FontWeight.w800,
      );
}

/// Returns the card surface color for the current context.
Color appListCardSurface(BuildContext context) =>
    AppColors.cardSurfaceFor(context);

/// Returns the card border color for the current context.
Color appListCardBorder(BuildContext context) =>
    AppColors.cardBorderFor(context);

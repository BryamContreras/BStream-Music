import 'package:flutter/material.dart';

class FavoriteStarBadge extends StatelessWidget {
  const FavoriteStarBadge({this.iconSize = 16, super.key});

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: iconSize + 5,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.star_rounded,
            size: iconSize + 5,
            color: const Color(0xF0000000),
            shadows: const [
              Shadow(color: Color(0xF0000000), blurRadius: 5),
              Shadow(color: Color(0xC0000000), blurRadius: 9),
            ],
          ),
          Icon(
            Icons.star_rounded,
            size: iconSize,
            color: const Color(0xFFFFD54F),
          ),
        ],
      ),
    );
  }
}

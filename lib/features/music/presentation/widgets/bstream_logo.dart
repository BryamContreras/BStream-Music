import 'package:flutter/material.dart';

class BStreamLogo extends StatelessWidget {
  const BStreamLogo({this.size = 40, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icons/bstream_icon.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      isAntiAlias: true,
    );
  }
}

import 'package:flutter/material.dart';

abstract final class AppColors {
  static const brandGreen = Color(0xFF18C75A);
  static const downloadAccent = Color(0xFF0E9F4D);
  static const downloadAccentDark = Color(0xFF0B8F43);
  static const downloadGradient = <Color>[downloadAccent, downloadAccentDark];
  static const playerControlForeground = Colors.white;
  static const playbackPrimaryBackground = Colors.white;
  static const playbackPrimaryForeground = Color(0xFF07110A);
  static const playbackPrimaryDisabledBackground = Color(0xFFD6DAD7);
  static const playbackPrimaryDisabledForeground = Color(0xFF505751);

  // Neutral overlay surfaces. Keeping these outside the seeded ColorScheme
  // prevents Material 3 from adding a green cast to menus and popovers.
  static const menuBackground = Color(0xF20A0A0A);
  static const menuBorder = Color(0x2EFFFFFF);
  static const menuForeground = Color(0xFFF4F4F4);
  static const neutralSliderInactive = Color(0xFF5A5A5A);
}

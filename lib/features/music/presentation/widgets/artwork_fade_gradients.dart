import 'package:flutter/material.dart';

// Shared transparent masks for expanded artwork. The image reveals the
// backdrop beneath it, so the same fade works with either app theme.
const expandedArtworkHeroEdgeFadeGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Colors.transparent,
    Colors.transparent,
    Color(0x0EFFFFFF),
    Color(0x33FFFFFF),
    Color(0x64FFFFFF),
    Color(0x9BFFFFFF),
    Color(0xCCFFFFFF),
    Color(0xF1FFFFFF),
    Colors.white,
    Colors.white,
    Color(0xF2FFFFFF),
    Color(0xD9FFFFFF),
    Color(0xA6FFFFFF),
    Color(0x66FFFFFF),
    Color(0x26FFFFFF),
    Color(0x08FFFFFF),
    Colors.transparent,
    Colors.transparent,
  ],
  // Finish the video blend before its texture is clipped. A transparent guard
  // keeps bright frames and fractional texture bounds from exposing a seam.
  stops: [
    0,
    0.05,
    0.06,
    0.07,
    0.08,
    0.09,
    0.10,
    0.11,
    0.12,
    0.66,
    0.72,
    0.78,
    0.84,
    0.90,
    0.93,
    0.95,
    0.96,
    1,
  ],
);

const expandedArtworkHeroBlurFadeGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Colors.white,
    Colors.white,
    Color(0xE6FFFFFF),
    Color(0x99FFFFFF),
    Colors.transparent,
  ],
  stops: [0, 0.70, 0.79, 0.91, 1],
);

const expandedArtworkHeroFocusFadeGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Colors.transparent,
    Colors.transparent,
    Color(0x0EFFFFFF),
    Color(0x33FFFFFF),
    Color(0x64FFFFFF),
    Color(0x9BFFFFFF),
    Color(0xCCFFFFFF),
    Color(0xF1FFFFFF),
    Colors.white,
    Colors.white,
    Color(0xF5FFFFFF),
    Color(0xDBFFFFFF),
    Color(0xB6FFFFFF),
    Color(0x8BFFFFFF),
    Color(0x5EFFFFFF),
    Color(0x35FFFFFF),
    Color(0x15FFFFFF),
    Color(0x03FFFFFF),
    Colors.transparent,
    Colors.transparent,
  ],
  // Transparent margins at both ends survive the maximum zoom and vertical
  // pan. The upper smoothstep blend meets the backdrop without a dark band.
  stops: [
    0,
    0.05,
    0.06,
    0.07,
    0.08,
    0.09,
    0.10,
    0.11,
    0.12,
    0.60,
    0.64,
    0.68,
    0.72,
    0.76,
    0.80,
    0.84,
    0.88,
    0.92,
    0.94,
    1,
  ],
);

const expandedArtworkBoundedEdgeFadeGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Colors.white, Colors.white, Colors.transparent],
  stops: [0, 0.84, 1],
);

const expandedArtworkBoundedVideoFadeGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Colors.white,
    Colors.white,
    Color(0xCCFFFFFF),
    Color(0x80FFFFFF),
    Color(0x26FFFFFF),
    Color(0x0AFFFFFF),
    Colors.transparent,
    Colors.transparent,
  ],
  // The guard also covers the small Canvas overscan on larger layouts.
  stops: [0, 0.84, 0.88, 0.91, 0.94, 0.95, 0.96, 1],
);

const expandedArtworkBoundedFocusFadeGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Colors.white, Colors.white, Color(0xB3FFFFFF), Colors.transparent],
  stops: [0, 0.68, 0.84, 1],
);

const expandedArtworkBoundedToneFadeStops = <double>[0, 0.74, 1];

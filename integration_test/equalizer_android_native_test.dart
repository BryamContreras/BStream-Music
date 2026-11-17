import 'dart:io';

import 'support/native_equalizer_scenarios.dart';

void main() =>
    registerNativeEqualizerScenarios(supportedPlatform: Platform.isAndroid);

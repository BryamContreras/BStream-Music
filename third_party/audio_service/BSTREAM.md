# BStream audio_service patch

Source: [`audio_service` 0.18.19](https://pub.dev/packages/audio_service/versions/0.18.19), MIT license retained in `LICENSE`.

The Dart library and Darwin implementation are unchanged upstream sources. Android has one compatibility patch in `AudioService.java`: explicitly named `MediaControl.custom` actions also receive notification actions on Android below API 33. Upstream publishes those actions only through `PlaybackState`, which Android 13+ SystemUI reads but older media notifications do not.

The legacy notification actions use immutable service `PendingIntent`s, identified by their encoded action URI. They re-enter the same `MediaSession` custom-action callback as modern Android, preserving cold-start handling and all standard transport controls. Android 13+ continues using its standard media-session action placement; its SystemUI controls the visual ordering.

The app reuses widget heart/repeat drawables and translates descriptions through its existing `AppStrings`. The repeat-all dot and repeat-one badge are lightweight layers over the widget repeat drawable.

No playback engine, media decoding, audio focus, queue, artwork cache or Darwin behavior was changed. Examples, upstream tests and build artifacts are omitted from the local package.

Primary platform reference: [Android media controls](https://developer.android.com/media/implement/surfaces/mobile).

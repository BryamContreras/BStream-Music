import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_binding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InnerTubeClientRegistry', () {
    test('uses benchmark winner VisionOS with resilient direct fallbacks', () {
      expect(InnerTubeClientRegistry.primary.key, 'visionOS');
      expect(
        InnerTubeClientRegistry.defaults.map((profile) => profile.key),
        <String>[
          'visionOS',
          'androidSdkless',
          'visionOS01',
          'webEmbedded',
          'mweb',
          'webMusic',
        ],
      );
      expect(
        InnerTubeClientRegistry.primary.capabilities.requiresPlayerJavaScript,
        isFalse,
      );
      expect(
        InnerTubeClientRegistry.primary.capabilities.mayNeedPoToken,
        isFalse,
      );
    });

    test('contains current profile versions and numeric IDs', () {
      expect(
        InnerTubeClientRegistry.all
            .map(
              (profile) =>
                  (profile.key, profile.clientId, profile.clientVersion),
            )
            .toList(),
        <(String, int, String)>[
          ('androidSdkless', 3, '21.26.364'),
          ('visionOS01', 101, '0.1'),
          ('visionOS', 101, '1.02'),
          ('tv', 7, '7.20260707.07.00'),
          ('tvDowngraded', 7, '5.20260707'),
          ('webEmbedded', 56, '2.20260708.00.00'),
          ('tvSimply', 75, '1.0'),
          ('mweb', 2, '2.20260708.05.00'),
          ('webMusic', 67, '1.20260707.12.00'),
          ('web', 1, '2.20260708.00.00'),
          ('ios', 5, '21.26.4'),
          ('androidVr', 28, '1.65.10'),
        ],
      );
    });

    test('keeps SDK-less Android tokenless and omits SDK metadata', () {
      final profile = InnerTubeClientRegistry.androidSdkless;
      final context = profile.buildClientContext();

      expect(profile.isExperimental, isFalse);
      expect(
        profile.capabilities.poTokenProvider,
        InnerTubePoTokenProvider.none,
      );
      expect(context, isNot(contains('androidSdkVersion')));
    });

    test('marks platform-token clients and disables Android VR', () {
      expect(
        InnerTubeClientRegistry.ios.capabilities.unsupportedByWebPo,
        isTrue,
      );
      expect(InnerTubeClientRegistry.androidVr.isEnabled, isFalse);
      expect(InnerTubeClientRegistry.all.last.key, 'androidVr');
      expect(
        InnerTubeClientRegistry.androidVr
            .buildClientContext()['androidSdkVersion'],
        32,
      );
    });

    test('marks web profiles as JS and WebPO capable', () {
      for (final profile in <InnerTubeClientProfile>[
        InnerTubeClientRegistry.mweb,
        InnerTubeClientRegistry.webMusic,
        InnerTubeClientRegistry.web,
      ]) {
        expect(profile.capabilities.requiresPlayerJavaScript, isTrue);
        expect(profile.capabilities.supportsWebPo, isTrue);
        expect(
          profile.capabilities.streamingDataPoToken,
          InnerTubePoTokenRequirement.required,
        );
      }
    });

    test('owns player and GVS bindings in each WebPO profile', () {
      expect(
        InnerTubeClientRegistry.webMusic.capabilities.playerPoTokenBinding,
        YoutubePoTokenBinding.visitorData,
      );
      expect(
        InnerTubeClientRegistry
            .webMusic
            .capabilities
            .streamingDataPoTokenBindings,
        <YoutubePoTokenBinding>[
          YoutubePoTokenBinding.videoId,
          YoutubePoTokenBinding.visitorData,
        ],
      );
      for (final profile in <InnerTubeClientProfile>[
        InnerTubeClientRegistry.mweb,
        InnerTubeClientRegistry.web,
      ]) {
        expect(
          profile.capabilities.playerPoTokenBinding,
          YoutubePoTokenBinding.videoId,
        );
        expect(
          profile.capabilities.streamingDataPoTokenBindings,
          <YoutubePoTokenBinding>[
            YoutubePoTokenBinding.videoId,
            YoutubePoTokenBinding.visitorData,
          ],
        );
      }
    });

    test('keeps tokenless JavaScript fallbacks ahead of WebPO', () {
      for (final profile in <InnerTubeClientProfile>[
        InnerTubeClientRegistry.tv,
        InnerTubeClientRegistry.tvDowngraded,
        InnerTubeClientRegistry.webEmbedded,
      ]) {
        expect(profile.capabilities.requiresPlayerJavaScript, isTrue);
        expect(profile.capabilities.mayNeedPoToken, isFalse);
      }
      expect(InnerTubeClientRegistry.webEmbedded.isEmbedded, isTrue);
      expect(
        InnerTubeClientRegistry.webEmbedded.buildContext(),
        isNot(contains('thirdParty')),
      );
    });

    test('keeps the downgraded TV version pinned', () {
      expect(InnerTubeClientRegistry.tv.allowDynamicClientVersion, isTrue);
      expect(
        InnerTubeClientRegistry.webEmbedded.allowDynamicClientVersion,
        isTrue,
      );
      expect(
        InnerTubeClientRegistry.tvDowngraded.allowDynamicClientVersion,
        isFalse,
      );
    });

    test('keeps narrow and unproven clients in their intended tiers', () {
      expect(InnerTubeClientRegistry.visionOS01.isFallbackOnly, isTrue);
      expect(InnerTubeClientRegistry.tvSimply.isExperimental, isTrue);
      expect(InnerTubeClientRegistry.tv.isExperimental, isTrue);
      expect(InnerTubeClientRegistry.tvDowngraded.isExperimental, isTrue);
      expect(InnerTubeClientRegistry.web.isExperimental, isTrue);
      expect(
        InnerTubeClientRegistry.defaults,
        contains(InnerTubeClientRegistry.visionOS01),
      );
      expect(
        InnerTubeClientRegistry.defaults,
        isNot(contains(InnerTubeClientRegistry.tvSimply)),
      );
      expect(
        InnerTubeClientRegistry.defaults,
        isNot(contains(InnerTubeClientRegistry.tv)),
      );
      expect(
        InnerTubeClientRegistry.defaults,
        isNot(contains(InnerTubeClientRegistry.web)),
      );
    });

    test('builds immutable headers and client context', () {
      final profile = InnerTubeClientRegistry.visionOS;
      final headers = profile.requestHeaders;
      final context = profile.buildClientContext(
        language: 'es',
        region: 'NI',
        visitorData: ' visitor ',
      );

      expect(headers['X-YouTube-Client-Name'], '101');
      expect(headers['X-YouTube-Client-Version'], '1.02');
      expect(headers['Origin'], profile.origin);
      expect(headers['X-Origin'], profile.origin);
      expect(headers['Referer'], '${profile.origin}/');
      expect(headers['X-Goog-Api-Format-Version'], '1');
      expect(profile.playerEndpoint.host, profile.host);
      expect(context['hl'], 'es');
      expect(context['gl'], 'NI');
      expect(context['visitorData'], 'visitor');
      expect(context['userAgent'], profile.userAgent);
      expect(() => context['hl'] = 'en', throwsUnsupportedError);
    });

    test('looks profiles up without accepting an unknown key', () {
      expect(
        InnerTubeClientRegistry.byKey('webMusic'),
        same(InnerTubeClientRegistry.webMusic),
      );
      expect(InnerTubeClientRegistry.byKey('missing'), isNull);
    });
  });
}

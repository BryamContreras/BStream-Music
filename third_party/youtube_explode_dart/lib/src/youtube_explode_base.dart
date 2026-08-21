import 'channels/channels.dart';
import 'playlists/playlist_client.dart';
import 'reverse_engineering/challenges/js_challenge.dart';
import 'reverse_engineering/po_token.dart';
import 'reverse_engineering/youtube_http_client.dart';
import 'search/search_client.dart';
import 'videos/video_client.dart';
import 'videos/youtube_api_client.dart';

/// Library entry point.
class YoutubeExplode {
  final YoutubeHttpClient _httpClient;

  /// Queries related to YouTube videos.
  late final VideoClient videos;

  /// Queries related to YouTube playlists.
  late final PlaylistClient playlists;

  /// Queries related to YouTube channels.
  late final ChannelClient channels;

  /// YouTube search queries.
  late final SearchClient search;

  late final BaseJSChallengeSolver? _jsSolver;
  final YoutubePoTokenProvider? _poTokenProvider;

  /// Initializes an instance of [YoutubeClient].
  YoutubeExplode({
    YoutubeHttpClient? httpClient,
    BaseJSChallengeSolver? jsSolver,
    YoutubeManifestClientsProvider? manifestClientsProvider,
    YoutubePoTokenProvider? poTokenProvider,
  })  : _httpClient = httpClient ?? YoutubeHttpClient(),
        _poTokenProvider = poTokenProvider {
    _jsSolver = jsSolver;
    videos = VideoClient(
      _httpClient,
      jsSolver: jsSolver,
      manifestClientsProvider: manifestClientsProvider,
      poTokenProvider: poTokenProvider,
    );
    playlists = PlaylistClient(_httpClient);
    channels = ChannelClient(_httpClient);
    search = SearchClient(_httpClient);
  }

  /// Closes the HttpClient assigned to this [YoutubeHttpClient].
  /// Should be called after this is not used anymore.
  void close() {
    _httpClient.close();
    _jsSolver?.dispose();
    _poTokenProvider?.dispose();
  }
}

/// PirateTok Live — TikTok Live connector via WSS.
///
/// Zero signer dependency. Only needs a ttwid cookie (unauthenticated GET
/// to tiktok.com). Connects directly to TikTok's WebSocket, no proxy servers.
library;

export 'src/client.dart' show TikTokLiveClient;
export 'src/errors.dart';
export 'src/events/types.dart' show EventType, TikTokEvent;
export 'src/helpers/gift_streak.dart' show GiftStreakTracker, GiftStreakEvent;
export 'src/helpers/like_accumulator.dart' show LikeAccumulator, LikeStats;
export 'src/helpers/profile_cache.dart' show ProfileCache;
export 'src/http/api.dart'
    show RoomIdResult, RoomInfo, StreamUrls, checkOnline, fetchRoomInfo;
export 'src/http/sigi.dart' show SigiProfile, scrapeProfile;

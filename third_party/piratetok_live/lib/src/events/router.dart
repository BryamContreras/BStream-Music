import 'dart:typed_data';

import '../proto/messages.dart';
import 'types.dart';

const _methodMap = {
  'WebcastChatMessage': EventType.chat,
  'WebcastGiftMessage': EventType.gift,
  'WebcastLikeMessage': EventType.like,
  'WebcastMemberMessage': EventType.member,
  'WebcastSocialMessage': EventType.social,
  'WebcastRoomUserSeqMessage': EventType.roomUserSeq,
  'WebcastControlMessage': EventType.control,
  'WebcastLiveIntroMessage': EventType.liveIntro,
  'WebcastRoomMessage': EventType.roomMessage,
  'WebcastCaptionMessage': EventType.caption,
  'WebcastGoalUpdateMessage': EventType.goalUpdate,
  'WebcastImDeleteMessage': EventType.imDelete,
  'WebcastRankUpdateMessage': EventType.rankUpdate,
  'WebcastPollMessage': EventType.poll,
  'WebcastEnvelopeMessage': EventType.envelope,
  'WebcastRoomPinMessage': EventType.roomPin,
  'WebcastUnauthorizedMemberMessage': EventType.unauthorizedMember,
  'WebcastLinkMicMethod': EventType.linkMicMethod,
  'WebcastLinkMicBattle': EventType.linkMicBattle,
  'WebcastLinkMicArmies': EventType.linkMicArmies,
  'WebcastLinkMessage': EventType.linkMessage,
  'WebcastLinkLayerMessage': EventType.linkLayer,
  'WebcastLinkMicLayoutStateMessage': EventType.linkMicLayoutState,
  'WebcastGiftPanelUpdateMessage': EventType.giftPanelUpdate,
  'WebcastInRoomBannerMessage': EventType.inRoomBanner,
  'WebcastGuideMessage': EventType.guide,
  'WebcastEmoteChatMessage': EventType.emoteChat,
  'WebcastQuestionNewMessage': EventType.questionNew,
  'WebcastSubNotifyMessage': EventType.subNotify,
  'WebcastBarrageMessage': EventType.barrage,
  'WebcastHourlyRankMessage': EventType.hourlyRank,
  'WebcastMsgDetectMessage': EventType.msgDetect,
  'WebcastLinkMicFanTicketMethod': EventType.linkMicFanTicket,
  'WebcastRoomVerifyMessage': EventType.roomVerify,
  'WebcastOecLiveShoppingMessage': EventType.oecLiveShopping,
  'WebcastGiftBroadcastMessage': EventType.giftBroadcast,
  'WebcastRankTextMessage': EventType.rankText,
  'WebcastGiftDynamicRestrictionMessage': EventType.giftDynamicRestriction,
  'WebcastViewerPicksUpdateMessage': EventType.viewerPicksUpdate,
  'WebcastAccessControlMessage': EventType.accessControl,
  'WebcastAccessRecallMessage': EventType.accessRecall,
  'WebcastAlertBoxAuditResultMessage': EventType.alertBoxAuditResult,
  'WebcastBindingGiftMessage': EventType.bindingGift,
  'WebcastBoostCardMessage': EventType.boostCard,
  'WebcastBottomMessage': EventType.bottom,
  'WebcastGameRankNotifyMessage': EventType.gameRankNotify,
  'WebcastGiftPromptMessage': EventType.giftPrompt,
  'WebcastLinkStateMessage': EventType.linkState,
  'WebcastLinkMicBattlePunishFinish': EventType.linkMicBattlePunishFinish,
  'WebcastLinkmicBattleTaskMessage': EventType.linkmicBattleTask,
  'WebcastMarqueeAnnouncementMessage': EventType.marqueeAnnouncement,
  'WebcastNoticeMessage': EventType.notice,
  'WebcastNotifyMessage': EventType.notify,
  'WebcastPartnershipDropsUpdateMessage': EventType.partnershipDropsUpdate,
  'WebcastPartnershipGameOfflineMessage': EventType.partnershipGameOffline,
  'WebcastPartnershipPunishMessage': EventType.partnershipPunish,
  'WebcastPerceptionMessage': EventType.perception,
  'WebcastSpeakerMessage': EventType.speaker,
  'WebcastSubCapsuleMessage': EventType.subCapsule,
  'WebcastSubPinEventMessage': EventType.subPinEvent,
  'WebcastSubscriptionNotifyMessage': EventType.subscriptionNotify,
  'WebcastToastMessage': EventType.toast,
  'WebcastSystemMessage': EventType.system,
  'WebcastLiveGameIntroMessage': EventType.liveGameIntro,
};

/// Decode a raw protobuf message into TikTok events.
/// Returns multiple events when sub-routing applies (e.g. Social → Follow).
List<TikTokEvent> decode(String method, Uint8List payload, String roomId) {
  final eventName = _methodMap[method];
  if (eventName == null) {
    return [
      TikTokEvent(EventType.unknown, {'method': method}, roomId),
    ];
  }

  final decoded = decodePayload(method, payload);
  if (decoded == null) {
    return [
      TikTokEvent(EventType.unknown, {'method': method}, roomId),
    ];
  }

  final events = <TikTokEvent>[TikTokEvent(eventName, decoded.data, roomId)];

  // Sub-routing: convenience events fire alongside raw events
  if (method == 'WebcastSocialMessage') {
    final action = decoded.data['action'] as int? ?? 0;
    if (action == 1) {
      events.add(TikTokEvent(EventType.follow, decoded.data, roomId));
    } else if (action >= 2 && action <= 5) {
      events.add(TikTokEvent(EventType.share, decoded.data, roomId));
    }
  } else if (method == 'WebcastMemberMessage') {
    final action = decoded.data['action'] as int? ?? 0;
    if (action == 1) {
      events.add(TikTokEvent(EventType.join, decoded.data, roomId));
    }
  } else if (method == 'WebcastControlMessage') {
    final action = decoded.data['action'] as int? ?? 0;
    if (action == 3) {
      events.add(TikTokEvent(EventType.liveEnded, decoded.data, roomId));
    }
  }

  return events;
}

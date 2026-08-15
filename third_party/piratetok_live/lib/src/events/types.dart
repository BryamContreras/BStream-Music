/// Event type constants for TikTok Live events.
abstract final class EventType {
  // Lifecycle
  static const connected = 'connected';
  static const websocketConnected = 'websocket_connected';
  static const disconnected = 'disconnected';
  static const reconnecting = 'reconnecting';
  static const unknown = 'unknown';

  // core
  static const chat = 'chat';
  static const gift = 'gift';
  static const like = 'like';
  static const member = 'member';
  static const social = 'social';
  static const roomUserSeq = 'room_user_seq';
  static const control = 'control';

  // Sub-routed convenience
  static const follow = 'follow';
  static const share = 'share';
  static const join = 'join';
  static const liveEnded = 'live_ended';

  // useful
  static const liveIntro = 'live_intro';
  static const roomMessage = 'room_message';
  static const caption = 'caption';
  static const goalUpdate = 'goal_update';
  static const imDelete = 'im_delete';

  // niche + extended
  static const rankUpdate = 'rank_update';
  static const poll = 'poll';
  static const envelope = 'envelope';
  static const roomPin = 'room_pin';
  static const unauthorizedMember = 'unauthorized_member';
  static const linkMicMethod = 'link_mic_method';
  static const linkMicBattle = 'link_mic_battle';
  static const linkMicArmies = 'link_mic_armies';
  static const linkMessage = 'link_message';
  static const linkLayer = 'link_layer';
  static const linkMicLayoutState = 'link_mic_layout_state';
  static const giftPanelUpdate = 'gift_panel_update';
  static const inRoomBanner = 'in_room_banner';
  static const guide = 'guide';
  static const emoteChat = 'emote_chat';
  static const questionNew = 'question_new';
  static const subNotify = 'sub_notify';
  static const barrage = 'barrage';
  static const hourlyRank = 'hourly_rank';
  static const msgDetect = 'msg_detect';
  static const linkMicFanTicket = 'link_mic_fan_ticket';
  static const roomVerify = 'room_verify';
  static const oecLiveShopping = 'oec_live_shopping';
  static const giftBroadcast = 'gift_broadcast';
  static const rankText = 'rank_text';
  static const giftDynamicRestriction = 'gift_dynamic_restriction';
  static const viewerPicksUpdate = 'viewer_picks_update';

  // secondary
  static const accessControl = 'access_control';
  static const accessRecall = 'access_recall';
  static const alertBoxAuditResult = 'alert_box_audit_result';
  static const bindingGift = 'binding_gift';
  static const boostCard = 'boost_card';
  static const bottom = 'bottom';
  static const gameRankNotify = 'game_rank_notify';
  static const giftPrompt = 'gift_prompt';
  static const linkState = 'link_state';
  static const linkMicBattlePunishFinish = 'link_mic_battle_punish_finish';
  static const linkmicBattleTask = 'linkmic_battle_task';
  static const marqueeAnnouncement = 'marquee_announcement';
  static const notice = 'notice';
  static const notify = 'notify';
  static const partnershipDropsUpdate = 'partnership_drops_update';
  static const partnershipGameOffline = 'partnership_game_offline';
  static const partnershipPunish = 'partnership_punish';
  static const perception = 'perception';
  static const speaker = 'speaker';
  static const subCapsule = 'sub_capsule';
  static const subPinEvent = 'sub_pin_event';
  static const subscriptionNotify = 'subscription_notify';
  static const toast = 'toast';
  static const system = 'system';
  static const liveGameIntro = 'live_game_intro';
}

/// A TikTok Live event with type, payload data, and room ID.
class TikTokEvent {
  final String type;
  final Map<String, dynamic>? data;
  final String roomId;

  const TikTokEvent(this.type, this.data, [this.roomId = '']);

  @override
  String toString() => 'TikTokEvent($type, roomId=$roomId)';
}

import 'dart:typed_data';

import 'codec.dart';

// === Common types ===

class Image {
  final List<String> urlList;
  final String uri;
  final int width;
  final int height;

  const Image({
    this.urlList = const [],
    this.uri = '',
    this.width = 0,
    this.height = 0,
  });

  factory Image.fromProto(ProtoMap m) => Image(
    urlList: m.getRepeatedString(1),
    uri: m.getString(2),
    width: m.getVarint(3),
    height: m.getVarint(4),
  );

  Map<String, dynamic> toJson() => {
    'urlList': urlList,
    'uri': uri,
    'width': width,
    'height': height,
  };
}

class PrivilegeLogExtra {
  final String dataVersion;
  final String privilegeId;
  final String privilegeVersion;
  final String level;

  const PrivilegeLogExtra({
    this.dataVersion = '',
    this.privilegeId = '',
    this.privilegeVersion = '',
    this.level = '',
  });

  factory PrivilegeLogExtra.fromProto(ProtoMap m) => PrivilegeLogExtra(
    dataVersion: m.getString(1),
    privilegeId: m.getString(2),
    privilegeVersion: m.getString(3),
    level: m.getString(5),
  );

  Map<String, dynamic> toJson() => {
    'dataVersion': dataVersion,
    'privilegeId': privilegeId,
    'level': level,
  };
}

class BadgeStruct {
  final int displayType;
  final int badgeScene;
  final bool display;
  final PrivilegeLogExtra? logExtra;

  const BadgeStruct({
    this.displayType = 0,
    this.badgeScene = 0,
    this.display = false,
    this.logExtra,
  });

  factory BadgeStruct.fromProto(ProtoMap m) => BadgeStruct(
    displayType: m.getVarint(1),
    badgeScene: m.getVarint(3),
    display: m.getBool(11),
    logExtra: m.getMessage(12) != null
        ? PrivilegeLogExtra.fromProto(m.getMessage(12)!)
        : null,
  );

  Map<String, dynamic> toJson() => {
    'displayType': displayType,
    'badgeScene': badgeScene,
    'display': display,
    if (logExtra != null) 'logExtra': logExtra!.toJson(),
  };
}

class FollowInfo {
  final int followingCount;
  final int followerCount;
  final int followStatus;

  const FollowInfo({
    this.followingCount = 0,
    this.followerCount = 0,
    this.followStatus = 0,
  });

  factory FollowInfo.fromProto(ProtoMap m) => FollowInfo(
    followingCount: m.getVarint(1),
    followerCount: m.getVarint(2),
    followStatus: m.getVarint(3),
  );

  Map<String, dynamic> toJson() => {
    'followingCount': followingCount,
    'followerCount': followerCount,
    'followStatus': followStatus,
  };
}

class FansClubData {
  final String clubName;
  final int level;

  const FansClubData({this.clubName = '', this.level = 0});

  factory FansClubData.fromProto(ProtoMap m) =>
      FansClubData(clubName: m.getString(1), level: m.getVarint(2));

  Map<String, dynamic> toJson() => {'clubName': clubName, 'level': level};
}

class User {
  final int id;
  final String nickname;
  final String bioDescription;
  final Image? avatarThumb;
  final Image? avatarMedium;
  final Image? avatarLarge;
  final bool verified;
  final FollowInfo? followInfo;
  final FansClubData? fansClub;
  final int topVipNo;
  final int payScore;
  final int fanTicketCount;
  final String uniqueId;
  final String displayId;
  final List<BadgeStruct> badgeList;
  final int followStatus;
  final bool isFollower;
  final bool isFollowing;
  final bool isSubscribe;

  const User({
    this.id = 0,
    this.nickname = '',
    this.bioDescription = '',
    this.avatarThumb,
    this.avatarMedium,
    this.avatarLarge,
    this.verified = false,
    this.followInfo,
    this.fansClub,
    this.topVipNo = 0,
    this.payScore = 0,
    this.fanTicketCount = 0,
    this.uniqueId = '',
    this.displayId = '',
    this.badgeList = const [],
    this.followStatus = 0,
    this.isFollower = false,
    this.isFollowing = false,
    this.isSubscribe = false,
  });

  factory User.fromProto(ProtoMap m) {
    final fansClubMsg = m.getMessage(24);
    FansClubData? fansClub;
    if (fansClubMsg != null) {
      final inner = fansClubMsg.getMessage(1);
      if (inner != null) fansClub = FansClubData.fromProto(inner);
    }
    return User(
      id: m.getVarint(1),
      nickname: m.getString(3),
      bioDescription: m.getString(5),
      avatarThumb: m.getMessage(9) != null
          ? Image.fromProto(m.getMessage(9)!)
          : null,
      avatarMedium: m.getMessage(10) != null
          ? Image.fromProto(m.getMessage(10)!)
          : null,
      avatarLarge: m.getMessage(11) != null
          ? Image.fromProto(m.getMessage(11)!)
          : null,
      verified: m.getBool(12),
      followInfo: m.getMessage(22) != null
          ? FollowInfo.fromProto(m.getMessage(22)!)
          : null,
      fansClub: fansClub,
      topVipNo: m.getVarint(31),
      payScore: m.getVarint(34),
      fanTicketCount: m.getVarint(35),
      uniqueId: m.getString(38),
      displayId: m.getString(46),
      badgeList: m.getRepeatedMessage(64).map(BadgeStruct.fromProto).toList(),
      followStatus: m.getVarint(1024),
      isFollower: m.getBool(1029),
      isFollowing: m.getBool(1030),
      isSubscribe: m.getBool(1090),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'nickname': nickname,
    'bioDescription': bioDescription,
    if (avatarThumb != null) 'avatarThumb': avatarThumb!.toJson(),
    'verified': verified,
    if (followInfo != null) 'followInfo': followInfo!.toJson(),
    if (fansClub != null) 'fansClub': fansClub!.toJson(),
    'topVipNo': topVipNo,
    'payScore': payScore,
    'fanTicketCount': fanTicketCount,
    'uniqueId': uniqueId,
    'displayId': displayId,
    'badgeList': badgeList.map((b) => b.toJson()).toList(),
    'followStatus': followStatus,
    'isFollower': isFollower,
    'isFollowing': isFollowing,
    'isSubscribe': isSubscribe,
  };
}

class Common {
  final String method;
  final int msgId;
  final int roomId;
  final int createTime;
  final String describe;

  const Common({
    this.method = '',
    this.msgId = 0,
    this.roomId = 0,
    this.createTime = 0,
    this.describe = '',
  });

  factory Common.fromProto(ProtoMap m) => Common(
    method: m.getString(1),
    msgId: m.getVarint(2),
    roomId: m.getVarint(3),
    createTime: m.getVarint(4),
    describe: m.getString(7),
  );
}

class GiftStruct {
  final Image? image;
  final String describe;
  final int duration;
  final int id;
  final bool combo;
  final int type;
  final int diamondCount;
  final String name;

  const GiftStruct({
    this.image,
    this.describe = '',
    this.duration = 0,
    this.id = 0,
    this.combo = false,
    this.type = 0,
    this.diamondCount = 0,
    this.name = '',
  });

  factory GiftStruct.fromProto(ProtoMap m) => GiftStruct(
    image: m.getMessage(1) != null ? Image.fromProto(m.getMessage(1)!) : null,
    describe: m.getString(2),
    duration: m.getVarint(4),
    id: m.getVarint(5),
    combo: m.getBool(10),
    type: m.getVarint(11),
    diamondCount: m.getVarint(12),
    name: m.getString(16),
  );

  Map<String, dynamic> toJson() => {
    if (image != null) 'image': image!.toJson(),
    'describe': describe,
    'id': id,
    'combo': combo,
    'type': type,
    'diamondCount': diamondCount,
    'name': name,
  };
}

class Emote {
  final String emoteId;
  final Image? image;

  const Emote({this.emoteId = '', this.image});

  factory Emote.fromProto(ProtoMap m) => Emote(
    emoteId: m.getString(1),
    image: m.getMessage(2) != null ? Image.fromProto(m.getMessage(2)!) : null,
  );

  Map<String, dynamic> toJson() => {
    'emoteId': emoteId,
    if (image != null) 'image': image!.toJson(),
  };
}

class UserIdentity {
  final bool isGiftGiverOfAnchor;
  final bool isSubscriberOfAnchor;
  final bool isMutualFollowingWithAnchor;
  final bool isFollowerOfAnchor;
  final bool isModeratorOfAnchor;
  final bool isAnchor;

  const UserIdentity({
    this.isGiftGiverOfAnchor = false,
    this.isSubscriberOfAnchor = false,
    this.isMutualFollowingWithAnchor = false,
    this.isFollowerOfAnchor = false,
    this.isModeratorOfAnchor = false,
    this.isAnchor = false,
  });

  factory UserIdentity.fromProto(ProtoMap m) => UserIdentity(
    isGiftGiverOfAnchor: m.getBool(1),
    isSubscriberOfAnchor: m.getBool(2),
    isMutualFollowingWithAnchor: m.getBool(3),
    isFollowerOfAnchor: m.getBool(4),
    isModeratorOfAnchor: m.getBool(5),
    isAnchor: m.getBool(6),
  );

  Map<String, dynamic> toJson() => {
    'isGiftGiverOfAnchor': isGiftGiverOfAnchor,
    'isSubscriberOfAnchor': isSubscriberOfAnchor,
    'isMutualFollowingWithAnchor': isMutualFollowingWithAnchor,
    'isFollowerOfAnchor': isFollowerOfAnchor,
    'isModeratorOfAnchor': isModeratorOfAnchor,
    'isAnchor': isAnchor,
  };
}

// === Decoded message types ===

typedef DecodedMessage = ({String type, Map<String, dynamic> data});

DecodedMessage decodeChat(ProtoMap m) {
  final user = m.getMessage(2);
  final userIdentity = m.getMessage(18);
  return (
    type: 'WebcastChatMessage',
    data: {
      'user': user != null ? User.fromProto(user).toJson() : null,
      'content': m.getString(3),
      'contentLanguage': m.getString(14),
      if (userIdentity != null)
        'userIdentity': UserIdentity.fromProto(userIdentity).toJson(),
    },
  );
}

DecodedMessage decodeGift(ProtoMap m) {
  final user = m.getMessage(7);
  final toUser = m.getMessage(8);
  final gift = m.getMessage(15);
  final repeatCount = m.getVarint(5);
  final repeatEnd = m.getVarint(9);
  final comboCount = m.getVarint(6);
  final giftStruct = gift != null ? GiftStruct.fromProto(gift) : null;
  final diamondCount = giftStruct?.diamondCount ?? 0;
  return (
    type: 'WebcastGiftMessage',
    data: {
      'giftId': m.getVarint(2),
      'fanTicketCount': m.getVarint(3),
      'groupCount': m.getVarint(4),
      'repeatCount': repeatCount,
      'comboCount': comboCount,
      'user': user != null ? User.fromProto(user).toJson() : null,
      'toUser': toUser != null ? User.fromProto(toUser).toJson() : null,
      'repeatEnd': repeatEnd,
      'groupId': m.getVarint(11),
      'gift': giftStruct?.toJson(),
      'sendType': m.getVarint(17),
      // convenience helpers
      'isComboGift': giftStruct?.combo ?? false,
      'isStreakOver': repeatEnd == 1,
      'diamondTotal': diamondCount * repeatCount,
    },
  );
}

DecodedMessage decodeLike(ProtoMap m) {
  final user = m.getMessage(5);
  return (
    type: 'WebcastLikeMessage',
    data: {
      'user': user != null ? User.fromProto(user).toJson() : null,
      'count': m.getVarint(2),
      'total': m.getVarint(3),
    },
  );
}

DecodedMessage decodeMember(ProtoMap m) {
  final user = m.getMessage(2);
  return (
    type: 'WebcastMemberMessage',
    data: {
      'user': user != null ? User.fromProto(user).toJson() : null,
      'memberCount': m.getVarint(3),
      'action': m.getVarint(10),
      'actionDescription': m.getString(11),
    },
  );
}

DecodedMessage decodeSocial(ProtoMap m) {
  final user = m.getMessage(2);
  return (
    type: 'WebcastSocialMessage',
    data: {
      'user': user != null ? User.fromProto(user).toJson() : null,
      'shareType': m.getVarint(3),
      'action': m.getVarint(4),
      'shareTarget': m.getString(5),
      'followCount': m.getVarint(6),
      'shareCount': m.getVarint(8),
    },
  );
}

DecodedMessage decodeRoomUserSeq(ProtoMap m) => (
  type: 'WebcastRoomUserSeqMessage',
  data: {
    'total': m.getVarint(3),
    'popStr': m.getString(4),
    'popularity': m.getVarint(6),
    'totalUser': m.getVarint(7),
  },
);

DecodedMessage decodeControl(ProtoMap m) => (
  type: 'WebcastControlMessage',
  data: {'action': m.getVarint(2), 'tips': m.getString(3)},
);

DecodedMessage decodeLiveIntro(ProtoMap m) {
  final host = m.getMessage(5);
  return (
    type: 'WebcastLiveIntroMessage',
    data: {
      'roomId': m.getVarint(2),
      'content': m.getString(4),
      'host': host != null ? User.fromProto(host).toJson() : null,
      'language': m.getString(8),
    },
  );
}

DecodedMessage decodeRoomMessage(ProtoMap m) =>
    (type: 'WebcastRoomMessage', data: {'content': m.getString(2)});

DecodedMessage decodeCaption(ProtoMap m) =>
    (type: 'WebcastCaptionMessage', data: {'timeStamp': m.getVarint(2)});

DecodedMessage decodeGoalUpdate(ProtoMap m) => (
  type: 'WebcastGoalUpdateMessage',
  data: {
    'contributorId': m.getVarint(4),
    'contributeCount': m.getVarint(9),
    'contributeScore': m.getVarint(10),
    'pin': m.getBool(13),
    'unpin': m.getBool(14),
  },
);

DecodedMessage decodeImDelete(ProtoMap m) => (
  type: 'WebcastImDeleteMessage',
  data: {
    'deleteMsgIds': m.getRepeatedVarint(2),
    'deleteUserIds': m.getRepeatedVarint(3),
  },
);

DecodedMessage decodeEmoteChat(ProtoMap m) {
  final user = m.getMessage(2);
  return (
    type: 'WebcastEmoteChatMessage',
    data: {
      'user': user != null ? User.fromProto(user).toJson() : null,
      'emoteList': m
          .getRepeatedMessage(3)
          .map(Emote.fromProto)
          .map((e) => e.toJson())
          .toList(),
    },
  );
}

DecodedMessage decodeSubNotify(ProtoMap m) {
  final user = m.getMessage(2);
  return (
    type: 'WebcastSubNotifyMessage',
    data: {
      'user': user != null ? User.fromProto(user).toJson() : null,
      'subMonth': m.getVarint(4),
    },
  );
}

/// Generic decoder for niche + secondary messages that only need
/// the raw ProtoMap preserved.
DecodedMessage decodeGeneric(String method, ProtoMap m) {
  final data = <String, dynamic>{'method': method};
  // Extract common fields if present
  if (m.has(2)) data['field2'] = m.getVarint(2);
  if (m.has(3)) data['field3'] = m.getVarint(3);
  return (type: method, data: data);
}

/// Decode an already parsed protobuf payload by method name.
///
/// Keeping this separate from [decodePayload] lets callers inspect cheap
/// top-level fields before constructing expensive nested objects such as the
/// full user attached to every chat message.
DecodedMessage decodeParsedPayload(String method, ProtoMap m) {
  return switch (method) {
    'WebcastChatMessage' => decodeChat(m),
    'WebcastGiftMessage' => decodeGift(m),
    'WebcastLikeMessage' => decodeLike(m),
    'WebcastMemberMessage' => decodeMember(m),
    'WebcastSocialMessage' => decodeSocial(m),
    'WebcastRoomUserSeqMessage' => decodeRoomUserSeq(m),
    'WebcastControlMessage' => decodeControl(m),
    'WebcastLiveIntroMessage' => decodeLiveIntro(m),
    'WebcastRoomMessage' => decodeRoomMessage(m),
    'WebcastCaptionMessage' => decodeCaption(m),
    'WebcastGoalUpdateMessage' => decodeGoalUpdate(m),
    'WebcastImDeleteMessage' => decodeImDelete(m),
    'WebcastEmoteChatMessage' => decodeEmoteChat(m),
    'WebcastSubNotifyMessage' => decodeSubNotify(m),
    _ => decodeGeneric(method, m),
  };
}

/// Decode a raw protobuf payload by method name.
DecodedMessage? decodePayload(String method, Uint8List payload) {
  final ProtoMap m;
  try {
    m = protoRead(payload);
  } on FormatException {
    return null;
  }

  return decodeParsedPayload(method, m);
}

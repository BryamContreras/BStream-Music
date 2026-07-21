import 'dart:convert';

import '../../domain/entities/playlist.dart';

class PlaylistModel extends Playlist {
  const PlaylistModel({
    required super.id,
    required super.name,
    required super.trackIds,
    required super.createdAt,
    required super.updatedAt,
  });

  factory PlaylistModel.fromMap(Map<String, Object?> map) {
    final rawIds = map['track_ids'] as String? ?? '[]';
    final ids = (jsonDecode(rawIds) as List).map((value) => value.toString());
    return PlaylistModel(
      id: map['id']! as String,
      name: map['name']! as String,
      trackIds: ids.toList(growable: false),
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
    );
  }

  factory PlaylistModel.fromEntity(Playlist playlist) {
    return PlaylistModel(
      id: playlist.id,
      name: playlist.name,
      trackIds: playlist.trackIds,
      createdAt: playlist.createdAt,
      updatedAt: playlist.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'track_ids': jsonEncode(trackIds),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

import 'package:equatable/equatable.dart';
import 'work.dart';
import 'audio_track.dart';

class HistoryRecord extends Equatable {
  final Work work;
  final DateTime lastPlayedTime;
  final AudioTrack? lastTrack;
  final int lastPositionMs;
  final int playlistIndex;
  final int playlistTotal;

  const HistoryRecord({
    required this.work,
    required this.lastPlayedTime,
    this.lastTrack,
    this.lastPositionMs = 0,
    this.playlistIndex = 0,
    this.playlistTotal = 0,
  });

  HistoryRecord copyWith({
    Work? work,
    DateTime? lastPlayedTime,
    AudioTrack? lastTrack,
    int? lastPositionMs,
    int? playlistIndex,
    int? playlistTotal,
  }) {
    return HistoryRecord(
      work: work ?? this.work,
      lastPlayedTime: lastPlayedTime ?? this.lastPlayedTime,
      lastTrack: lastTrack ?? this.lastTrack,
      lastPositionMs: lastPositionMs ?? this.lastPositionMs,
      playlistIndex: playlistIndex ?? this.playlistIndex,
      playlistTotal: playlistTotal ?? this.playlistTotal,
    );
  }

  @override
  List<Object?> get props => [
        work,
        lastPlayedTime,
        lastTrack,
        lastPositionMs,
        playlistIndex,
        playlistTotal,
      ];
}

import 'package:equatable/equatable.dart';

/// Where a [Transition] lies relative to the cut between its clips.
enum TransitionAlignment {
  /// Half before the cut, half after it.
  center,

  /// Entirely after the cut.
  startAtCut,

  /// Entirely before the cut.
  endAtCut,
}

/// An explicit crossfade between two adjacent clips on one track.
///
/// Around the cut the outgoing clip ([fromClipId]) is extended past its end
/// and the incoming clip ([toClipId]) before its start; where a clip has no
/// material there (trimmed to the source edge, not looping) its edge frame
/// holds. The length is limited by [fitTransitions].
class Transition extends Equatable {
  final String id;

  /// The earlier (outgoing) clip.
  final String fromClipId;

  /// The later (incoming) clip, directly after [fromClipId].
  final String toClipId;

  /// Length of the crossfade, positive.
  final Duration duration;

  final TransitionAlignment alignment;

  Transition({
    required this.id,
    required this.fromClipId,
    required this.toClipId,
    required this.duration,
    this.alignment = TransitionAlignment.center,
  }) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (fromClipId == toClipId) {
      throw ArgumentError.value(toClipId, 'toClipId', 'A transition needs two different clips.');
    }
    if (duration <= Duration.zero) throw ArgumentError.value(duration, 'duration', 'Must be positive.');
  }

  /// Part of the crossfade before the cut, inside the outgoing clip.
  Duration get partBefore => partBeforeFor(duration, alignment);

  /// Part of the crossfade after the cut, inside the incoming clip.
  Duration get partAfter => duration - partBefore;

  /// Part before the cut of a crossfade of [duration] with [alignment].
  static Duration partBeforeFor(Duration duration, TransitionAlignment alignment) => switch (alignment) {
        TransitionAlignment.center => Duration(microseconds: duration.inMicroseconds ~/ 2),
        TransitionAlignment.startAtCut => Duration.zero,
        TransitionAlignment.endAtCut => duration,
      };

  Transition copyWith({Duration? duration, TransitionAlignment? alignment}) => Transition(
        id: id,
        fromClipId: fromClipId,
        toClipId: toClipId,
        duration: duration ?? this.duration,
        alignment: alignment ?? this.alignment,
      );

  @override
  List<Object?> get props => [id, fromClipId, toClipId, duration, alignment];
}

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

/// How a [Transition] blends its two clips; see the Compositor for the exact
/// pixel rules.
enum TransitionKind {
  /// The outgoing clip fades out while the incoming one fades in.
  crossfade,

  /// A soft-edged edge moves across the stage in [TransitionDirection],
  /// revealing the incoming clip behind it.
  wipe,

  /// The outgoing clip fades to black in the first half, the incoming one
  /// fades in from black in the second.
  dipToBlack,

  /// Like [dipToBlack] through white.
  dipToWhite,

  /// The incoming clip slides in from [TransitionDirection], pushing the
  /// outgoing one out.
  push,
}

/// The side a [TransitionKind.wipe] or [TransitionKind.push] starts from:
/// the incoming clip enters from there.
///
/// [left] is icicle 0 (the motion goes towards the last icicle), [right]
/// the last icicle, [up] the top of the icicles (LED 0, the motion goes
/// down), [down] their bottom. [center] wipes from the middle icicle
/// outward; a push treats it as [left].
enum TransitionDirection { left, right, up, down, center }

/// An explicit transition between two adjacent clips on one track.
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

  /// Length of the transition, positive.
  final Duration duration;

  final TransitionAlignment alignment;

  final TransitionKind kind;

  /// Used by [TransitionKind.wipe] and [TransitionKind.push] only.
  final TransitionDirection direction;

  Transition({
    required this.id,
    required this.fromClipId,
    required this.toClipId,
    required this.duration,
    this.alignment = TransitionAlignment.center,
    this.kind = TransitionKind.crossfade,
    this.direction = TransitionDirection.left,
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

  /// Whether this is a plain crossfade as stored by version 1 documents.
  bool get isClassic => kind == TransitionKind.crossfade && direction == TransitionDirection.left;

  Transition copyWith({
    Duration? duration,
    TransitionAlignment? alignment,
    TransitionKind? kind,
    TransitionDirection? direction,
  }) =>
      Transition(
        id: id,
        fromClipId: fromClipId,
        toClipId: toClipId,
        duration: duration ?? this.duration,
        alignment: alignment ?? this.alignment,
        kind: kind ?? this.kind,
        direction: direction ?? this.direction,
      );

  @override
  List<Object?> get props => [id, fromClipId, toClipId, duration, alignment, kind, direction];
}

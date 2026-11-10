import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';

import 'clip.dart';
import 'transition.dart';
import 'transition_fitting.dart';

/// A layer of clips. Tracks are composited bottom to top; clips on one
/// track never overlap.
class VisualTrack extends Equatable {
  final String id;
  final String name;

  /// A muted track is not drawn.
  final bool muted;

  /// While any track of the composition is solo, only the solo tracks are
  /// drawn (a muted solo track stays silent).
  final bool solo;

  /// The edit operations refuse to change the clips of a locked track.
  final bool locked;

  /// In `[0, 1]`, multiplies the opacity of every clip.
  final double opacity;

  /// Sorted by start, never overlapping.
  final List<Clip> clips;

  /// Crossfades between adjacent clips, valid per [fitTransitions].
  final List<Transition> transitions;

  /// Sorts [clips] by start. Throws an [ArgumentError] when clips overlap,
  /// clip ids repeat or a transition does not fit as is.
  VisualTrack({
    required this.id,
    this.name = '',
    this.muted = false,
    this.solo = false,
    this.locked = false,
    this.opacity = 1.0,
    List<Clip> clips = const [],
    List<Transition> transitions = const [],
  })  : clips = List.unmodifiable(clips.sorted((a, b) => a.start.compareTo(b.start))),
        transitions = List.unmodifiable(transitions) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (!opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError.value(opacity, 'opacity', 'Must be in [0, 1].');
    }
    final ids = <String>{};
    for (final (index, clip) in this.clips.indexed) {
      if (!ids.add(clip.id)) throw ArgumentError('Duplicate clip id "${clip.id}" on track "$id".');
      if (index > 0 && this.clips[index - 1].end > clip.start) {
        throw ArgumentError('Clips "${this.clips[index - 1].id}" and "${clip.id}" overlap on track "$id".');
      }
    }
    final fitted = fitTransitions(this.clips, this.transitions);
    if (fitted.issues.isNotEmpty) {
      throw ArgumentError('Invalid transitions on track "$id": ${fitted.issues}.');
    }
  }

  /// End of the last clip.
  Duration get end => clips.isEmpty ? Duration.zero : clips.map((clip) => clip.end).max;

  Clip? clipById(String clipId) => clips.firstWhereOrNull((clip) => clip.id == clipId);

  Transition? transitionById(String transitionId) =>
      transitions.firstWhereOrNull((transition) => transition.id == transitionId);

  /// The transition ending at the start of [clipId].
  Transition? transitionInto(String clipId) =>
      transitions.firstWhereOrNull((transition) => transition.toClipId == clipId);

  /// The transition starting at the end of [clipId].
  Transition? transitionOutOf(String clipId) =>
      transitions.firstWhereOrNull((transition) => transition.fromClipId == clipId);

  VisualTrack copyWith({
    String? name,
    bool? muted,
    bool? solo,
    bool? locked,
    double? opacity,
    List<Clip>? clips,
    List<Transition>? transitions,
  }) =>
      VisualTrack(
        id: id,
        name: name ?? this.name,
        muted: muted ?? this.muted,
        solo: solo ?? this.solo,
        locked: locked ?? this.locked,
        opacity: opacity ?? this.opacity,
        clips: clips ?? this.clips,
        transitions: transitions ?? this.transitions,
      );

  @override
  List<Object?> get props => [id, name, muted, solo, locked, opacity, clips, transitions];
}

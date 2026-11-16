import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:icicles_generators/icicles_generators.dart';

import 'clip_label.dart';

/// One mark of a [CueTrack]: a moment on the timeline a cue trigger fires
/// at, with a [strength] (`0..1`; a flash peaks at it).
class Cue extends Equatable {
  final String id;

  /// Timeline time, never negative.
  final Duration at;

  /// `0..1`.
  final double strength;

  /// Throws an [ArgumentError] for an empty [id], a negative [at] or a
  /// [strength] outside `0..1`.
  Cue({required this.id, required this.at, this.strength = 1}) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (at.isNegative) throw ArgumentError.value(at, 'at', 'Must not be negative.');
    if (!strength.isFinite || strength < 0 || strength > 1) {
      throw ArgumentError.value(strength, 'strength', 'Must be within 0..1.');
    }
  }

  Cue copyWith({Duration? at, double? strength}) =>
      Cue(id: id, at: at ?? this.at, strength: strength ?? this.strength);

  @override
  List<Object?> get props => [id, at, strength];
}

/// A timing track: named, colored marks on the timeline ("cues") that
/// generator and effect clips with a cue trigger fire on — placed by hand,
/// tapped along with the music or filled from detected drum hits, like the
/// timing tracks of light sequencers.
class CueTrack extends Equatable {
  final String id;
  final String name;
  final ClipLabel color;

  /// Sorted by time (stable); ids unique within the track.
  final List<Cue> cues;

  /// Throws an [ArgumentError] for an empty [id] or repeated cue ids.
  CueTrack({required this.id, this.name = '', this.color = ClipLabel.none, List<Cue> cues = const []})
      : cues = List.unmodifiable(cues.sortedBy<Duration>((cue) => cue.at)) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    final ids = <String>{};
    for (final cue in this.cues) {
      if (!ids.add(cue.id)) throw ArgumentError('Duplicate cue id "${cue.id}" in cue track "$id".');
    }
  }

  Cue? cueById(String cueId) => cues.firstWhereOrNull((cue) => cue.id == cueId);

  /// The cues as events on a clock where timeline time `t` is `t + offset`
  /// (what a bake takes as `BakeRequest.cues`: song time is timeline time
  /// minus the soundtrack offset).
  CueHits hits({Duration offset = Duration.zero}) =>
      CueHits([for (final cue in cues) CueHit(cue.at + offset, cue.strength)]);

  CueTrack copyWith({String? name, ClipLabel? color, List<Cue>? cues}) =>
      CueTrack(id: id, name: name ?? this.name, color: color ?? this.color, cues: cues ?? this.cues);

  @override
  List<Object?> get props => [id, name, color, cues];
}

import 'package:equatable/equatable.dart';

import '../model/composition.dart';

/// What a time snapped to, in priority order for equally near targets.
/// [audioHit] is never produced by [Snapper]: it labels the detected audio
/// events (e.g. drum hits) a host adds as targets of its own.
enum SnapTargetKind { playhead, clipEdge, marker, cue, beat, audioHit }

/// A snapped time.
class SnapResult extends Equatable {
  /// The time snapped to.
  final Duration time;

  final SnapTargetKind kind;

  const SnapResult(this.time, this.kind);

  @override
  List<Object?> get props => [time, kind];
}

/// A snapped span (a clip being moved): its new start and the edge that
/// snapped.
class SpanSnapResult extends Equatable {
  /// The start of the span after snapping.
  final Duration start;

  /// What the snapped edge landed on.
  final SnapResult snap;

  /// Whether the end edge snapped (otherwise the start edge).
  final bool snappedEnd;

  const SpanSnapResult({required this.start, required this.snap, required this.snappedEnd});

  @override
  List<Object?> get props => [start, snap, snappedEnd];
}

/// Snaps times to beats, clip edges, the playhead, markers and the cues of
/// the cue tracks within
/// [tolerance] (the caller converts its pixel tolerance at the current zoom).
class Snapper {
  final Duration tolerance;
  final bool beats;
  final bool clipEdges;
  final bool playhead;
  final bool markers;
  final bool cues;

  const Snapper({
    required this.tolerance,
    this.beats = true,
    this.clipEdges = true,
    this.playhead = true,
    this.markers = true,
    this.cues = true,
  });

  /// The target nearest to [time] within [tolerance], or `null`.
  ///
  /// Edges of the clips in [ignoreClipIds] (the clips being dragged) are not
  /// targets. Beats come from [Composition.tempo].
  SnapResult? snap(
    Composition composition,
    Duration time, {
    Duration? playheadAt,
    Set<String> ignoreClipIds = const {},
    Set<String> ignoreCueIds = const {},
  }) {
    SnapResult? best;
    var bestDistance = 0;
    void consider(Duration target, SnapTargetKind kind) {
      final distance = (target - time).inMicroseconds.abs();
      if (distance > tolerance.inMicroseconds) return;
      if (best == null || distance < bestDistance || (distance == bestDistance && kind.index < best!.kind.index)) {
        best = SnapResult(target, kind);
        bestDistance = distance;
      }
    }

    if (playhead && playheadAt != null) consider(playheadAt, SnapTargetKind.playhead);
    if (clipEdges) {
      for (final (track: _, :clip) in composition.placedClips) {
        if (ignoreClipIds.contains(clip.id)) continue;
        consider(clip.start, SnapTargetKind.clipEdge);
        consider(clip.end, SnapTargetKind.clipEdge);
      }
    }
    if (markers) {
      for (final marker in composition.markers) {
        consider(marker.at, SnapTargetKind.marker);
      }
    }
    if (cues) {
      for (final track in composition.cueTracks) {
        for (final cue in track.cues) {
          if (!ignoreCueIds.contains(cue.id)) consider(cue.at, SnapTargetKind.cue);
        }
      }
    }
    final tempo = composition.tempo;
    if (beats && tempo != null) consider(tempo.nearestBeat(time), SnapTargetKind.beat);
    return best;
  }

  /// Snaps a span of [length] starting at [start] by whichever edge is
  /// nearer to a target; `null` when neither edge is within [tolerance].
  /// The start never becomes negative.
  SpanSnapResult? snapSpan(
    Composition composition,
    Duration start,
    Duration length, {
    Duration? playheadAt,
    Set<String> ignoreClipIds = const {},
  }) {
    final startSnap = snap(composition, start, playheadAt: playheadAt, ignoreClipIds: ignoreClipIds);
    final endSnap = snap(composition, start + length, playheadAt: playheadAt, ignoreClipIds: ignoreClipIds);
    SpanSnapResult? fromEnd;
    if (endSnap != null && endSnap.time - length >= Duration.zero) {
      fromEnd = SpanSnapResult(start: endSnap.time - length, snap: endSnap, snappedEnd: true);
    }
    final fromStart =
        startSnap == null ? null : SpanSnapResult(start: startSnap.time, snap: startSnap, snappedEnd: false);
    if (fromStart == null) return fromEnd;
    if (fromEnd == null) return fromStart;
    final startDistance = (startSnap!.time - start).inMicroseconds.abs();
    final endDistance = (endSnap!.time - (start + length)).inMicroseconds.abs();
    return endDistance < startDistance ? fromEnd : fromStart;
  }
}

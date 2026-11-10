import 'package:icicles_animation_dart/icicles_animation_dart.dart';

import '../model/source_ref.dart';

/// Why an [EffectHost] could not apply an effect.
enum EffectHostErrorKind {
  /// The effect is not installed (or the host has no runner for the clip).
  unavailable,

  /// The effect threw while processing the frame.
  failed,
}

/// Thrown by [EffectHost.apply]; the compositor then treats the clip as
/// offline (`OfflineReason.effectUnavailable` / `effectFailed`) and passes
/// the input through.
class EffectHostException implements Exception {
  final EffectHostErrorKind kind;

  /// Technical description, not meant for end users.
  final String message;

  const EffectHostException(this.kind, this.message);

  @override
  String toString() => 'EffectHostException(${kind.name}): $message';
}

/// Runs the effects of [EffectRef] clips for the compositor, which stays
/// pure: the application owns the effect catalog and the per-clip runners
/// (an `EffectRunner` of _icicles_generators_ is sequential and keeps the
/// effect's state between frames, so one runner per clip).
abstract interface class EffectHost {
  /// The effect of [ref] applied to [input] (the layers below the clip
  /// [clipId], in the composition target layout) at effect frame
  /// [frameIndex] — the grid frame of the clip's source time,
  /// `frameIndexAt(framerate, sourceTime)`, in `[0, frameCountFor(framerate,
  /// ref.length))`. The compositor asks for the frames of one clip in
  /// timeline order within one render (an index not after the last one
  /// means the run restarted, e.g. a scrub backwards in the preview).
  ///
  /// Returns a view of the same layout. Throws an [EffectHostException].
  AnimationView apply(String clipId, EffectRef ref, int frameIndex, AnimationView input);
}

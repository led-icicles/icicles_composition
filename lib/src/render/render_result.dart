import 'package:equatable/equatable.dart';
import 'package:icicles_animation_dart/icicles_animation_dart.dart';

import '../model/source_ref.dart';

/// What a [RenderWarning] is about.
enum RenderWarningKind {
  /// Some clips were not drawn because their source is missing, empty or does
  /// not match the target layout; see [OfflineSourcesWarning].
  offlineSources,

  /// The export holds a standalone pause longer than the controller plays;
  /// see [FirmwareDelayTruncationWarning].
  firmwareDelayTruncation,
}

/// A non-fatal problem of a render; the application shows it before saving.
sealed class RenderWarning extends Equatable {
  const RenderWarning();

  RenderWarningKind get kind;

  /// Technical description, not meant for end users.
  String get message;
}

/// Why a clip was not drawn.
enum OfflineReason {
  /// No index was given for the source.
  missing,

  /// The source has no frames to show.
  empty,

  /// The source frames do not have the target pixels and radio panels shape.
  layoutMismatch,

  /// The generator of a [GeneratorRef] is not installed (or has another
  /// version). Reported by the application, which bakes the generators; the
  /// compositor itself only sees a missing index.
  generatorUnavailable,

  /// Baking the generator failed. Reported by the application like
  /// [generatorUnavailable].
  generatorFailed,

  /// The effect of an [EffectRef] clip could not run: the render had no
  /// `EffectHost`, or the host reported the effect as not installed
  /// (`EffectHostErrorKind.unavailable`). The clip passes its input through.
  effectUnavailable,

  /// The `EffectHost` failed while applying the effect
  /// (`EffectHostErrorKind.failed`). The clip passes its input through.
  effectFailed,
}

/// A clip that was not drawn.
class OfflineClip extends Equatable {
  final String clipId;
  final SourceRef source;
  final OfflineReason reason;

  const OfflineClip({required this.clipId, required this.source, required this.reason});

  @override
  List<Object?> get props => [clipId, source, reason];
}

/// Clips of unmuted tracks that were rendered as transparent.
class OfflineSourcesWarning extends RenderWarning {
  final List<OfflineClip> clips;

  const OfflineSourcesWarning(this.clips);

  @override
  RenderWarningKind get kind => RenderWarningKind.offlineSources;

  @override
  String get message => 'Clips with offline sources were not drawn: '
      '${clips.map((clip) => '${clip.clipId} (${clip.source.label}, ${clip.reason.name})').join(', ')}.';

  @override
  List<Object?> get props => [clips];
}

/// A standalone delay frame of the export.
class LongDelay extends Equatable {
  /// Time at which the pause starts in the exported animation.
  final Duration at;

  final Duration duration;

  const LongDelay({required this.at, required this.duration});

  @override
  List<Object?> get props => [at, duration];
}

/// The export holds standalone [DelayFrame]s longer than
/// [FirmwareDelayTruncationWarning.controllerLimit]: the controller may
/// shorten these pauses (it reads their duration as 8 bits), so the
/// animation can run ahead of the music on hardware.
class FirmwareDelayTruncationWarning extends RenderWarning {
  /// Longest standalone pause the controller plays as stored.
  static const controllerLimit = Duration(milliseconds: 255);

  final List<LongDelay> delays;

  const FirmwareDelayTruncationWarning(this.delays);

  @override
  RenderWarningKind get kind => RenderWarningKind.firmwareDelayTruncation;

  @override
  String get message => 'The controller may shorten ${delays.length} pause(s) longer than '
      '${controllerLimit.inMilliseconds} ms: '
      '${delays.map((delay) => '${delay.duration.inMilliseconds} ms at ${delay.at}').join(', ')}.';

  @override
  List<Object?> get props => [delays];
}

/// The exported animation and the problems found while rendering it.
class RenderResult {
  final Animation animation;
  final List<RenderWarning> warnings;

  RenderResult({required this.animation, required List<RenderWarning> warnings})
      : warnings = List.unmodifiable(warnings);

  /// The first warning of type [T], if any.
  T? warning<T extends RenderWarning>() {
    for (final warning in warnings) {
      if (warning is T) return warning;
    }
    return null;
  }
}

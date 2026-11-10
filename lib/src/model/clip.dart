import 'package:equatable/equatable.dart';
import 'package:icicles_animation_dart/icicles_animation_dart.dart';

import 'clip_label.dart';
import 'region.dart';
import 'source_ref.dart';

/// A placement of a trimmed, optionally stretched and looped range of a
/// source animation on a track.
///
/// The trim is `[sourceIn, sourceOut)` in source time. The timeline length
/// is the derived [duration]; there is no stored length that rounding could
/// make inconsistent.
class Clip extends Equatable {
  /// Lowest allowed [speed].
  static const minSpeed = 0.1;

  /// Highest allowed [speed].
  static const maxSpeed = 10.0;

  /// Shortest timeline length the edit operations produce.
  static const minDuration = Duration(milliseconds: 1);

  final String id;
  final SourceRef source;

  /// Timeline time of the clip start, never negative.
  final Duration start;

  /// Start of the trimmed source range (inclusive).
  final Duration sourceIn;

  /// End of the trimmed source range (exclusive).
  final Duration sourceOut;

  /// Playback rate of the source: `2` plays twice as fast (half the
  /// length), `0.5` half as fast. In `[minSpeed, maxSpeed]`.
  final double speed;

  /// Timeline length of a looping clip, which repeats the trimmed range;
  /// `null` plays the range once.
  final Duration? loopDuration;

  final BlendMode blend;

  /// In `[0, 1]`.
  final double opacity;

  final Duration fadeIn;
  final Duration fadeOut;
  final Region region;

  /// A mask clip is not drawn itself: while active, its per-pixel luminance
  /// (of its composited output, with its opacity, fades and region; pixels
  /// outside the region count as 1) multiplies everything the tracks
  /// below it have drawn at that instant (a track matte). Never set on an
  /// effect clip.
  final bool isMask;

  /// Plays the trimmed range backwards (the last source frame first).
  final bool reverse;

  /// A looping clip plays the range forward on one pass and backward on the
  /// next (with [reverse], backward first). Only a looping clip can ping-pong.
  final bool pingPong;

  /// Color label on the timeline; no effect on the render.
  final ClipLabel label;

  /// Throws an [ArgumentError] for values outside their documented ranges.
  Clip({
    required this.id,
    required this.source,
    required this.start,
    required this.sourceIn,
    required this.sourceOut,
    this.speed = 1.0,
    this.loopDuration,
    this.blend = BlendMode.normal,
    this.opacity = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.region = const Region.all(),
    this.isMask = false,
    this.reverse = false,
    this.pingPong = false,
    this.label = ClipLabel.none,
  }) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (start.isNegative) throw ArgumentError.value(start, 'start', 'Must not be negative.');
    if (sourceIn.isNegative) throw ArgumentError.value(sourceIn, 'sourceIn', 'Must not be negative.');
    if (sourceOut <= sourceIn) {
      throw ArgumentError.value(sourceOut, 'sourceOut', 'Must be after sourceIn ($sourceIn).');
    }
    if (!speed.isFinite || speed < minSpeed || speed > maxSpeed) {
      throw ArgumentError.value(speed, 'speed', 'Must be in [$minSpeed, $maxSpeed].');
    }
    final loop = loopDuration;
    if (loop != null && loop <= Duration.zero) {
      throw ArgumentError.value(loop, 'loopDuration', 'Must be positive.');
    }
    if (!opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError.value(opacity, 'opacity', 'Must be in [0, 1].');
    }
    if (fadeIn.isNegative) throw ArgumentError.value(fadeIn, 'fadeIn', 'Must not be negative.');
    if (fadeOut.isNegative) throw ArgumentError.value(fadeOut, 'fadeOut', 'Must not be negative.');
    if (duration <= Duration.zero) {
      throw ArgumentError('The clip must last at least 1 µs on the timeline (range $sourceRange, speed $speed).');
    }
    if (pingPong && loop == null) {
      throw ArgumentError.value(pingPong, 'pingPong', 'Only a looping clip can ping-pong.');
    }
    if (source case ParametricRef(:final length)) {
      if (speed != 1.0) {
        throw ArgumentError.value(speed, 'speed', 'A generator or effect clip always plays at speed 1.');
      }
      if (loop != null) throw ArgumentError.value(loop, 'loopDuration', 'A generator or effect clip never loops.');
      if (sourceOut > length) {
        throw ArgumentError.value(sourceOut, 'sourceOut', 'Must not exceed the source length ($length).');
      }
    }
    if (isMask && source is EffectRef) {
      throw ArgumentError.value(isMask, 'isMask', 'An effect clip cannot be a mask.');
    }
  }

  /// Whether [source] is a [GeneratorRef]: the clip plays at speed 1 and
  /// never loops.
  bool get isGenerator => source is GeneratorRef;

  /// Whether [source] is an [EffectRef]: an adjustment layer over the
  /// tracks below; plays at speed 1, never loops and is never a mask.
  bool get isEffect => source is EffectRef;

  /// Whether [source] is a [ParametricRef] (a generator or an effect).
  bool get isParametric => source is ParametricRef;

  /// Length of the trimmed source range.
  Duration get sourceRange => sourceOut - sourceIn;

  /// Timeline length of one pass of the trimmed range at [speed].
  Duration get passDuration => Duration(microseconds: (sourceRange.inMicroseconds / speed).round());

  /// The only length on the timeline: [loopDuration] for a looping clip,
  /// otherwise [passDuration].
  Duration get duration => loopDuration ?? passDuration;

  /// Timeline time of the clip end (exclusive).
  Duration get end => start + duration;

  bool get isLooping => loopDuration != null;

  /// Whether [time] is in `[start, end)`.
  bool contains(Duration time) => time >= start && time < end;

  /// Source time shown at timeline [time], which should be in `[start, end)`.
  ///
  /// The scaled local time is rounded down (never to nearest), wrapped into
  /// the range when looping (mirrored on every other pass with [pingPong]),
  /// mirrored with [reverse] and clamped to `[sourceIn, sourceOut − 1 µs]`,
  /// so the end of the range is never sampled even when rounding would land
  /// on it.
  Duration sourceTimeAt(Duration time) => Duration(
          microseconds: _clamp(
        sourceIn.inMicroseconds + _scaledOffset(time),
        sourceIn.inMicroseconds,
        sourceOut.inMicroseconds - 1,
      ));

  /// Source time shown at timeline [time] when a transition extends the clip
  /// beyond `[start, end)`.
  ///
  /// A looping clip keeps cycling. Otherwise the material after [sourceOut]
  /// (before [sourceIn]) is used up to the edge of the source, whose length
  /// is [sourceLength]; where none is left the edge frame holds (freezes).
  Duration extendedSourceTimeAt(Duration time, Duration sourceLength) {
    final offset = _scaledOffset(time);
    final int lower;
    final int upper;
    // A reversed clip runs out of material at the other end of the source.
    final past = time >= end ? !reverse : reverse;
    if (isLooping) {
      lower = sourceIn.inMicroseconds;
      upper = sourceOut.inMicroseconds - 1;
    } else if (past) {
      lower = sourceIn.inMicroseconds;
      upper = sourceLength.inMicroseconds - 1;
    } else {
      lower = 0;
      upper = sourceOut.inMicroseconds - 1;
    }
    return Duration(microseconds: _clamp(sourceIn.inMicroseconds + offset, lower, upper));
  }

  /// Offset into the trimmed range at timeline [time]: the floor of the
  /// local time scaled by [speed], wrapped (and mirrored every other pass
  /// with [pingPong]) when looping, mirrored with [reverse]. Outside the
  /// clip of a non-looping clip it runs past the range (negative or beyond
  /// it), which [extendedSourceTimeAt] clamps.
  int _scaledOffset(Duration time) {
    final range = sourceRange.inMicroseconds;
    var scaled = ((time - start).inMicroseconds * speed).floor();
    if (isLooping) {
      if (pingPong) {
        final phase = scaled % (2 * range);
        scaled = phase < range ? phase : 2 * range - 1 - phase;
      } else {
        scaled %= range;
      }
    }
    return reverse ? range - 1 - scaled : scaled;
  }

  static int _clamp(int value, int lower, int upper) => value < lower ? lower : (value > upper ? upper : value);

  /// Fade factor in `[0, 1]` at timeline [time]; times outside the clip
  /// use the nearest clip edge.
  double fadeAt(Duration time) {
    final length = duration.inMicroseconds;
    final local = _clamp((time - start).inMicroseconds, 0, length);
    var factor = 1.0;
    if (fadeIn > Duration.zero) {
      factor = local / fadeIn.inMicroseconds;
    }
    if (fadeOut > Duration.zero) {
      final out = (length - local) / fadeOut.inMicroseconds;
      if (out < factor) factor = out;
    }
    return factor < 0 ? 0 : (factor > 1 ? 1 : factor);
  }

  /// A copy with the given fields replaced; [removeLoop] sets
  /// [loopDuration] to `null`.
  Clip copyWith({
    String? id,
    SourceRef? source,
    Duration? start,
    Duration? sourceIn,
    Duration? sourceOut,
    double? speed,
    Duration? loopDuration,
    bool removeLoop = false,
    BlendMode? blend,
    double? opacity,
    Duration? fadeIn,
    Duration? fadeOut,
    Region? region,
    bool? isMask,
    bool? reverse,
    bool? pingPong,
    ClipLabel? label,
  }) =>
      Clip(
        id: id ?? this.id,
        source: source ?? this.source,
        start: start ?? this.start,
        sourceIn: sourceIn ?? this.sourceIn,
        sourceOut: sourceOut ?? this.sourceOut,
        speed: speed ?? this.speed,
        loopDuration: removeLoop ? null : (loopDuration ?? this.loopDuration),
        blend: blend ?? this.blend,
        opacity: opacity ?? this.opacity,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        region: region ?? this.region,
        isMask: isMask ?? this.isMask,
        reverse: reverse ?? this.reverse,
        pingPong: removeLoop ? false : (pingPong ?? this.pingPong),
        label: label ?? this.label,
      );

  @override
  List<Object?> get props => [
        id,
        source,
        start,
        sourceIn,
        sourceOut,
        speed,
        loopDuration,
        blend,
        opacity,
        fadeIn,
        fadeOut,
        region,
        isMask,
        reverse,
        pingPong,
        label,
      ];
}

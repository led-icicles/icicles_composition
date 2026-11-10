import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_generators/icicles_generators.dart';

import '../edit/composition_exception.dart';
import '../model/clip.dart';
import '../model/composition.dart';
import '../model/loop_range.dart';
import '../model/region.dart';
import '../model/source_ref.dart';
import '../model/transition.dart';
import '../model/visual_track.dart';
import 'effect_host.dart';
import 'render_result.dart';

/// Renders compositions: single views for the preview ([renderAt]) and
/// whole animations for the export ([render]).
///
/// Sources are single-pass [AnimationIndex]es ([Animation.toIndex]) keyed by
/// [SourceRef]: decoded files for [AnimationFileRef]s and, for
/// [GeneratorRef]s, the bakes the application made at the target layout
/// (an absent bake is a missing source, see [OfflineReason]). [EffectRef]
/// clips have no index: their effect runs per frame through the
/// [EffectHost] the application passes (without one every effect clip is
/// offline and passes its input through). Memory grows with frames ×
/// pixels of every source, which is fine for icicle-sized grids (e.g.
/// 24×20) but worth keeping in mind for large ones.
abstract final class Compositor {
  /// The view at timeline [time].
  ///
  /// Starts from opaque black (like [Animation.play] and the `.anim`
  /// encoder), then composites the active clips of every unmuted track
  /// (while any track is solo, of the solo tracks only), bottom track first, with [Color.composite] in the clip's blend mode.
  /// Each source color's alpha is scaled by
  /// `clip.opacity × fade(time) × track.opacity × transitionWeight(time)`.
  /// Clips whose source is missing or does not match the target shape are
  /// not drawn (transparent). A clip's [Region] limits the columns, panels
  /// and (with a [PixelMask]) the single pixels it touches.
  ///
  /// A mask clip ([Clip.isMask]) is not drawn: at every pixel its own
  /// composited output (its colors with the clip opacity, fades and
  /// transition weight over black; pixels outside its region count as
  /// white) gives a luminance in `[0, 1]` ([Color.computeLuminance]) that
  /// scales the color the lower tracks (and the earlier layers of its own
  /// track) have accumulated so far at that pixel — a track matte. Because
  /// the background is opaque black, scaling the accumulated color toward
  /// black is the same as scaling its alpha over that background. The
  /// tracks above the mask are composited afterwards and are unaffected.
  ///
  /// An effect clip ([Clip.isEffect]) is an adjustment layer: the picture
  /// accumulated so far (the tracks below and the earlier layers of its
  /// track) is handed to [effects] as the input of the effect at the grid
  /// frame of the clip's source time, and the result is composited back
  /// over the input with the clip's blend mode at the same alpha factor as
  /// a normal clip (opacity × fades × track opacity × transition weight; at
  /// `normal` and factor 1 the result replaces the input, a lower factor
  /// mixes them), inside the clip's region only — elsewhere the input
  /// passes through. Without [effects], or when the host throws an
  /// [EffectHostException], the clip is offline and the input passes
  /// through unchanged.
  ///
  /// The view's frame duration is that of the grid frame containing [time].
  static AnimationView renderAt(
    Composition composition,
    Map<SourceRef, AnimationIndex> sources,
    Duration time, {
    EffectHost? effects,
  }) {
    if (time.isNegative) throw RangeError.value(time.inMicroseconds, 'time', 'Must not be negative.');
    final frame = frameIndexAt(composition.framerate, time);
    return _Renderer(composition, sources, effects).viewAt(time, composition.framerate.frameDuration(frame));
  }

  /// Renders the whole timeline (or the first [duration] of it, or the
  /// grid frames covering [range]) into one animation on the drift-free
  /// frame grid: frame `i` is [renderAt] sampled at
  /// `framerate.frameStart(i)`, written with [Icicles.setView] and shown
  /// for `framerate.frameDuration(i)`. With [range], the first exported
  /// frame is the grid frame containing `range.start` and the last the one
  /// containing the last microsecond before `range.end`, so the export of
  /// a range shows exactly the preview frames of that span.
  ///
  /// The animation has the [Composition.target] header, plays once
  /// (`loopsCount: 1`), is optimized (additive/delay frames) and uses
  /// 24-bit colors (`useRgb565: false`; the controller reads only frame
  /// types 1, 2, 3, 100 and 101). Its length is the grid time of the frames
  /// covering the timeline, at most one frame longer than it.
  ///
  /// Effect clips run through [effects] frame by frame in timeline order
  /// (see [renderAt]). Offline sources and effects do not block the
  /// export; they are reported in [RenderResult.warnings] with standalone
  /// pauses the controller may shorten. Throws
  /// [CompositionErrorKind.emptyComposition] when there is nothing to
  /// render.
  static RenderResult render(
    Composition composition,
    Map<SourceRef, AnimationIndex> sources, {
    Duration? duration,
    LoopRange? range,
    EffectHost? effects,
  }) {
    final framerate = composition.framerate;
    final int firstFrame;
    final int frames;
    if (range != null) {
      firstFrame = frameIndexAt(framerate, range.start);
      frames = frameIndexAt(framerate, range.end - const Duration(microseconds: 1)) - firstFrame + 1;
    } else {
      final length = duration ?? composition.duration;
      if (length <= Duration.zero) {
        throw const CompositionException(CompositionErrorKind.emptyComposition, 'The composition has no length.');
      }
      firstFrame = 0;
      frames = frameCountFor(framerate, length);
    }
    final target = composition.target;
    final animation = Animation(
      composition.name,
      xCount: target.xCount,
      yCount: target.yCount,
      optimize: true,
      useRgb565: false,
      framerate: framerate,
      loopsCount: 1,
      version: target.version,
      radioPanelsCount: target.radioPanelsCount,
      radioPanelPixelCount: target.radioPanelPixelCount,
    );
    final icicles = Icicles(animation);
    final renderer = _Renderer(composition, sources, effects);
    for (var index = firstFrame; index < firstFrame + frames; index++) {
      final frameDuration = framerate.frameDuration(index);
      icicles.setView(renderer.viewAt(framerate.frameStart(index), frameDuration));
      icicles.show(frameDuration);
    }

    final warnings = <RenderWarning>[];
    final offline = renderer.offlineClips();
    if (offline.isNotEmpty) warnings.add(OfflineSourcesWarning(offline));
    final delays = <LongDelay>[];
    var at = Duration.zero;
    for (final frame in animation.frames) {
      if (frame is DelayFrame && frame.duration > FirmwareDelayTruncationWarning.controllerLimit) {
        delays.add(LongDelay(at: at, duration: frame.duration));
      }
      at += frame.duration;
    }
    if (delays.isNotEmpty) warnings.add(FirmwareDelayTruncationWarning(delays));
    return RenderResult(animation: animation, warnings: warnings);
  }

  /// Clips of audible (unmuted, and solo while any track is solo) tracks
  /// that [renderAt] does not draw because their source is missing, empty
  /// or does not have the target shape, and effect clips that cannot run
  /// without [effects] (`effectUnavailable`). Failures a host reports
  /// while rendering are known only to [render], which lists them in its
  /// warnings.
  static List<OfflineClip> offlineClips(
    Composition composition,
    Map<SourceRef, AnimationIndex> sources, {
    EffectHost? effects,
  }) =>
      _offlineClips(composition, _sourceStatus(composition, sources, effects), const {});
}

List<OfflineClip> _offlineClips(
  Composition composition,
  Map<SourceRef, OfflineReason> status,
  Map<String, OfflineReason> failedClips,
) =>
    [
      for (final track in composition.tracks)
        if (composition.isTrackAudible(track))
          for (final clip in track.clips)
            if (status[clip.source] ?? failedClips[clip.id] case final reason?)
              OfflineClip(clipId: clip.id, source: clip.source, reason: reason),
    ];

/// The offline reason of each unusable source of [composition].
Map<SourceRef, OfflineReason> _sourceStatus(
  Composition composition,
  Map<SourceRef, AnimationIndex> sources,
  EffectHost? effects,
) {
  final status = <SourceRef, OfflineReason>{};
  for (final source in composition.sources) {
    if (source is EffectRef) {
      if (effects == null) status[source] = OfflineReason.effectUnavailable;
      continue;
    }
    final index = sources[source];
    if (index == null) {
      status[source] = OfflineReason.missing;
    } else if (index.views.isEmpty) {
      status[source] = OfflineReason.empty;
    } else if (!composition.target.matchesView(index.views.first)) {
      status[source] = OfflineReason.layoutMismatch;
    }
  }
  return status;
}

/// One clip drawn at one time; [index] is null for an effect clip.
class _Layer {
  final Clip clip;
  final AnimationIndex? index;
  final Duration sourceTime;
  final double factor;

  const _Layer(this.clip, this.index, this.sourceTime, this.factor);
}

/// A transition window on the timeline.
class _Window {
  final Transition transition;
  final Duration start;
  final Duration end;

  _Window(this.transition, Duration cut)
      : start = cut - transition.partBefore,
        end = cut + transition.partAfter;

  bool contains(Duration time) => time >= start && time < end;

  double progress(Duration time) => (time - start).inMicroseconds / (end - start).inMicroseconds;
}

class _Renderer {
  final Composition composition;
  final Map<SourceRef, AnimationIndex> sources;
  final EffectHost? effects;
  final Map<SourceRef, OfflineReason> _offline;

  /// Effect clips whose host failed during this render; they pass their
  /// input through from then on.
  final _failedClips = <String, OfflineReason>{};

  _Renderer(this.composition, this.sources, this.effects) : _offline = _sourceStatus(composition, sources, effects);

  /// Offline clips, including the effect clips that failed so far.
  List<OfflineClip> offlineClips() => _offlineClips(composition, _offline, _failedClips);

  AnimationView viewAt(Duration time, Duration frameDuration) {
    final target = composition.target;
    final pixels = List<Color>.filled(target.pixelsCount, Colors.black);
    final panels = List.generate(
      target.radioPanelsCount,
      (_) => List<Color>.filled(target.radioPanelPixelCount, Colors.black),
    );
    for (final track in composition.tracks) {
      if (!composition.isTrackAudible(track) || track.opacity <= 0) continue;
      for (final layer in _layers(track, time)) {
        if (layer.clip.isEffect) {
          _applyEffect(layer, pixels, panels, frameDuration);
        } else if (layer.clip.isMask) {
          _applyMask(layer, pixels, panels);
        } else {
          _draw(layer, pixels, panels);
        }
      }
    }
    return AnimationView(
      VisualFrame(duration: frameDuration, pixels: pixels),
      [for (final (index, colors) in panels.indexed) RadioPanelView(index + 1, colors)],
    );
  }

  bool _usable(Clip clip) => !_offline.containsKey(clip.source) && !_failedClips.containsKey(clip.id);

  AnimationIndex? _usableIndex(Clip clip) => _usable(clip) ? sources[clip.source] : null;

  /// Length of one pass of the clip's source: the index length, or the
  /// effect ref's length.
  Duration _sourceLength(Clip clip, AnimationIndex? index) => index?.duration ?? (clip.source as ParametricRef).length;

  /// Base alpha factor of [clip] at [time], without transition weights.
  double _factor(VisualTrack track, Clip clip, Duration time) => clip.opacity * clip.fadeAt(time) * track.opacity;

  /// The clips of [track] drawn at [time], in drawing order.
  List<_Layer> _layers(VisualTrack track, Duration time) {
    final layers = <_Layer>[];
    for (final (position, clip) in track.clips.indexed) {
      final into = track.transitionInto(clip.id);
      final outOf = track.transitionOutOf(clip.id);
      final intoWindow = into == null ? null : _Window(into, clip.start);
      final outWindow = outOf == null ? null : _Window(outOf, track.clips[position + 1].start);
      final inIntoWindow = intoWindow != null && intoWindow.contains(time);
      final inOutWindow = outWindow != null && outWindow.contains(time);
      if (!clip.contains(time) && !inIntoWindow && !inOutWindow) continue;

      if (!_usable(clip)) continue;
      final index = _usableIndex(clip);
      if (index == null && !clip.isEffect) continue;
      var factor = _factor(track, clip, time);
      if (inIntoWindow) {
        // Incoming clip: weight p.
        factor *= intoWindow.progress(time);
      } else if (inOutWindow) {
        // Outgoing clip: weight (1 − p) / (1 − p·s) where s is the incoming
        // alpha factor, so that under the incoming clip its visible share
        // falls linearly to 0 (a true dissolve for opaque clips).
        final p = outWindow.progress(time);
        final next = track.clips[position + 1];
        final incoming =
            _usable(next) && (next.isEffect || _usableIndex(next) != null) ? _factor(track, next, time) : 0.0;
        final denominator = 1 - p * incoming;
        factor *= denominator <= 1e-12 ? 0.0 : (1 - p) / denominator;
      }
      if (factor <= 0) continue;

      final length = _sourceLength(clip, index);
      final sourceTime = clip.contains(time) ? clip.sourceTimeAt(time) : clip.extendedSourceTimeAt(time, length);
      layers.add(_Layer(clip, index, _clampToLength(sourceTime, length), factor));
    }
    return layers;
  }

  /// Keeps the time inside the source even when it got shorter than the
  /// trim.
  static Duration _clampToLength(Duration time, Duration length) {
    final last = length - const Duration(microseconds: 1);
    if (time > last) return last;
    if (time.isNegative) return Duration.zero;
    return time;
  }

  /// Column range `[from, to)` of the pixels a region touches, or null
  /// when it touches no icicle pixel.
  (int, int)? _columnSpan(Region region) {
    if (!region.coversIcicles) return null;
    // Pixels are column-major: column x holds the indices
    // [x·yCount, (x+1)·yCount).
    final target = composition.target;
    final columns = region.columns;
    final first = columns == null ? 0 : columns.first.clamp(0, target.xCount);
    final last = columns == null ? target.xCount - 1 : columns.last.clamp(-1, target.xCount - 1);
    if (first > last) return null;
    return (first * target.yCount, (last + 1) * target.yCount);
  }

  void _draw(_Layer layer, List<Color> pixels, List<List<Color>> panels) {
    final view = layer.index!.viewAt(layer.sourceTime);
    final clip = layer.clip;
    final region = clip.region;
    final mask = region.pixels;
    if (_columnSpan(region) case (final from, final to)) {
      _composite(view.frame.pixels, pixels, layer.factor, clip.blend, from: from, to: to, included: mask?.contains);
    }
    if (region.coversRadioPanels) {
      for (final panel in view.radioPanels) {
        if (!region.affectsPanel(panel.index)) continue;
        _composite(panel.colors, panels[panel.index - 1], layer.factor, clip.blend,
            included: mask == null ? null : (led) => mask.containsPanelPixel(panel.index, led));
      }
    }
  }

  /// Multiplies the accumulated [pixels] and [panels] by the luminance of
  /// the mask clip [layer] at every pixel of its region.
  void _applyMask(_Layer layer, List<Color> pixels, List<List<Color>> panels) {
    final view = layer.index!.viewAt(layer.sourceTime);
    final clip = layer.clip;
    final region = clip.region;
    final mask = region.pixels;
    if (_columnSpan(region) case (final from, final to)) {
      _multiply(view.frame.pixels, pixels, layer.factor, clip.blend, from: from, to: to, included: mask?.contains);
    }
    if (region.coversRadioPanels) {
      for (final panel in view.radioPanels) {
        if (!region.affectsPanel(panel.index)) continue;
        _multiply(panel.colors, panels[panel.index - 1], layer.factor, clip.blend,
            included: mask == null ? null : (led) => mask.containsPanelPixel(panel.index, led));
      }
    }
  }

  /// Runs the effect of [layer] over the accumulated [pixels] and [panels]
  /// and composites the result back inside the clip's region.
  void _applyEffect(_Layer layer, List<Color> pixels, List<List<Color>> panels, Duration frameDuration) {
    final host = effects;
    final clip = layer.clip;
    final ref = clip.source as EffectRef;
    if (host == null) return;
    final input = AnimationView(
      VisualFrame(duration: frameDuration, pixels: List<Color>.of(pixels)),
      [for (final (index, colors) in panels.indexed) RadioPanelView(index + 1, List<Color>.of(colors))],
    );
    final AnimationView output;
    try {
      output = host.apply(clip.id, ref, frameIndexAt(composition.framerate, layer.sourceTime), input);
    } on EffectHostException catch (error) {
      _failedClips[clip.id] = switch (error.kind) {
        EffectHostErrorKind.unavailable => OfflineReason.effectUnavailable,
        EffectHostErrorKind.failed => OfflineReason.effectFailed,
      };
      return;
    }
    if (output.frame.pixels.length != pixels.length ||
        output.radioPanels.length != panels.length ||
        output.radioPanels.any((panel) => panel.colors.length != composition.target.radioPanelPixelCount)) {
      _failedClips[clip.id] = OfflineReason.effectFailed;
      return;
    }
    final region = clip.region;
    final mask = region.pixels;
    if (_columnSpan(region) case (final from, final to)) {
      _composite(output.frame.pixels, pixels, layer.factor, clip.blend, from: from, to: to, included: mask?.contains);
    }
    if (region.coversRadioPanels) {
      for (final panel in output.radioPanels) {
        if (!region.affectsPanel(panel.index)) continue;
        _composite(panel.colors, panels[panel.index - 1], layer.factor, clip.blend,
            included: mask == null ? null : (led) => mask.containsPanelPixel(panel.index, led));
      }
    }
  }

  /// The source color with its alpha scaled by [factor], or `null` when
  /// nothing of it is left.
  static Color? _scaled(Color color, double factor) {
    final alpha = (color.alpha * factor).round();
    if (alpha <= 0) return null;
    return alpha >= color.alpha ? color : color.withAlpha(alpha);
  }

  /// Composites `source[i]` over `destination[i]` for `i` in `[from, to)`
  /// (the whole list by default) where [included] (every pixel by default)
  /// allows it.
  static void _composite(List<Color> source, List<Color> destination, double factor, BlendMode blend,
      {int from = 0, int? to, bool Function(int index)? included}) {
    final end = to ?? destination.length;
    for (var i = from; i < end; i++) {
      if (included != null && !included(i)) continue;
      final scaled = _scaled(source[i], factor);
      if (scaled == null) continue;
      destination[i] = Color.composite(scaled, destination[i], blend);
    }
  }

  /// Scales `destination[i]` toward black by the luminance of `source[i]`
  /// composited over black (with [factor] and [blend]) for `i` in
  /// `[from, to)` where [included] allows it.
  static void _multiply(List<Color> source, List<Color> destination, double factor, BlendMode blend,
      {int from = 0, int? to, bool Function(int index)? included}) {
    final end = to ?? destination.length;
    for (var i = from; i < end; i++) {
      if (included != null && !included(i)) continue;
      final scaled = _scaled(source[i], factor);
      final luminance = scaled == null ? 0.0 : Color.composite(scaled, Colors.black, blend).computeLuminance();
      final color = destination[i];
      destination[i] = Color.fromARGB(
        color.alpha,
        (color.red * luminance).round(),
        (color.green * luminance).round(),
        (color.blue * luminance).round(),
      );
    }
  }
}

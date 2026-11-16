import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_generators/icicles_generators.dart';

import '../edit/composition_exception.dart';
import '../model/clip.dart';
import '../model/composition.dart';
import '../model/loop_range.dart';
import '../model/output_spec.dart';
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
  /// Transitions ([Transition.kind]) at progress `p` (0 … 1 across the
  /// transition window), each clip keeping its own alpha factor, blend
  /// mode and region:
  /// - `crossfade`: the incoming clip at weight `p`, the outgoing one as
  ///   described above for the alpha factor (a true dissolve).
  /// - `wipe`: per pixel the incoming clip's weight is
  ///   `clamp((p·1.15 − u) / 0.15, 0, 1)` (a soft edge 15 % of the span
  ///   wide) and the outgoing clip dissolves against it like in a
  ///   crossfade; `u` (0 … 1) is the pixel's position from the
  ///   [Transition.direction] side: along the icicles for left/right,
  ///   along the LEDs (LED 0 is the top) for up/down, the distance from the
  ///   middle icicle for center. Radio panel `i` of `n` sits at
  ///   `(i + 0.5) / n` along the icicles for left/right/center; for up/down
  ///   the panels crossfade.
  /// - `dipToBlack` / `dipToWhite`: while `p < 0.5` only the outgoing clip is
  ///   drawn, its colors mixed toward opaque black/white by `2p`; from
  ///   `p = 0.5` only the incoming clip, mixed by `2(1 − p)`.
  /// - `push`: the incoming clip slides in from the direction side by
  ///   whole icicles (`round(p · xCount)`, left/right/center) or LEDs
  ///   (`round(p · yCount)`, up/down), the outgoing one moves out the other
  ///   way; regions stay in place, the pictures move through them. The
  ///   radio panels crossfade. Effect clips are not shifted (their output
  ///   lines up with their input), only the boundary between them moves.
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
  /// covering the timeline, at most one frame longer than it — or, with
  /// [exactLength], exactly the timeline (or [range]) length to the
  /// millisecond: the last frame is shown only until the end.
  ///
  /// Effect clips run through [effects] frame by frame in timeline order
  /// (see [renderAt]). Offline sources and effects do not block the
  /// export; they are reported in [RenderResult.warnings] with standalone
  /// pauses the controller may shorten. Throws
  /// [CompositionErrorKind.emptyComposition] when there is nothing to
  /// render.
  /// How long the last frame (starting at [start], normally [full]) shows so
  /// the animation ends at [end]: whole milliseconds, never shorter than
  /// [full] (a short remainder was merged into it, so it may be longer).
  static Duration _until(Duration start, Duration end, Duration full) {
    final until = _ms(end - start);
    return until < full ? full : until;
  }

  static Duration _ms(Duration d) => Duration(milliseconds: (d.inMicroseconds / 1000).round());

  static RenderResult render(
    Composition composition,
    Map<SourceRef, AnimationIndex> sources, {
    Duration? duration,
    LoopRange? range,
    EffectHost? effects,
    bool exactLength = false,
  }) {
    final framerate = composition.framerate;
    final int firstFrame;
    final int frames;
    final Duration end;
    if (range != null) {
      end = range.end;
      firstFrame = frameIndexAt(framerate, range.start);
      frames = frameIndexAt(framerate, range.end - const Duration(microseconds: 1)) - firstFrame + 1;
    } else {
      final length = duration ?? composition.duration;
      if (length <= Duration.zero) {
        throw const CompositionException(CompositionErrorKind.emptyComposition, 'The composition has no length.');
      }
      firstFrame = 0;
      frames = frameCountFor(framerate, length);
      end = length;
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
    var last = firstFrame + frames - 1;
    // A remainder shorter than the shortest frame extends the frame before.
    if (exactLength && last > firstFrame && _ms(end - framerate.frameStart(last)) < framerate.minFrameDuration) {
      last--;
    }
    for (var index = firstFrame; index <= last; index++) {
      final start = framerate.frameStart(index);
      final frameDuration = framerate.frameDuration(index);
      icicles.setView(renderer.viewAt(start, frameDuration));
      icicles.show(exactLength && index == last ? _until(start, end, frameDuration) : frameDuration);
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
///
/// Inside a non-crossfade transition [pixelWeights] / [panelWeights]
/// multiply [factor] per destination icicle pixel / per panel (0-based),
/// [remap] gives the source pixel shown at each destination icicle pixel
/// (`-1`: none, the pixel is not drawn) and [overlay] is mixed into the
/// clip's own colors by [overlayAmount] before they are composited.
class _Layer {
  final Clip clip;
  final AnimationIndex? index;
  final Duration sourceTime;
  final double factor;
  final List<double>? pixelWeights;
  final List<double>? panelWeights;
  final List<int>? remap;
  final Color? overlay;
  final double overlayAmount;

  const _Layer(
    this.clip,
    this.index,
    this.sourceTime,
    this.factor, {
    this.pixelWeights,
    this.panelWeights,
    this.remap,
    this.overlay,
    this.overlayAmount = 0,
  });

  /// The per-pixel options of [_Renderer._composite] / [_Renderer._multiply]
  /// for the icicle pixels.
  _PixelOptions get pixelOptions => _PixelOptions(pixelWeights, remap, overlay, overlayAmount);

  /// The options for the pixels of panel [panelIndex] (0-based).
  _PixelOptions panelOptions(int panelIndex) => _PixelOptions(null, null, overlay, overlayAmount);

  /// [factor] for panel [panelIndex] (0-based).
  double panelFactor(int panelIndex) => factor * (panelWeights?[panelIndex] ?? 1);
}

/// Per-pixel parts of a [_Layer].
class _PixelOptions {
  final List<double>? weights;
  final List<int>? remap;
  final Color? overlay;
  final double overlayAmount;

  const _PixelOptions(this.weights, this.remap, this.overlay, this.overlayAmount);

  static const none = _PixelOptions(null, null, null, 0);

  bool get isNone => weights == null && remap == null && overlay == null;
}

/// How the two clips of a non-crossfade transition share the stage at one
/// progress `p` (see [Compositor.renderAt]): the incoming clip's spatial
/// share per icicle pixel ([incomingPixels]) and per panel
/// ([incomingPanels]), the source pixels each clip shows (push), and the
/// dip color with the amount of it mixed into the visible clip.
class _TransitionShape {
  /// Soft edge of a wipe, as a share of its span.
  static const wipeSoftness = 0.15;

  final List<double>? incomingPixels;
  final List<double>? incomingPanels;
  final List<int>? incomingRemap;
  final List<int>? outgoingRemap;
  final Color? dip;

  /// Dip only: the outgoing clip is shown (first half), else the incoming.
  final bool dipShowsOutgoing;
  final double dipAmount;

  const _TransitionShape({
    this.incomingPixels,
    this.incomingPanels,
    this.incomingRemap,
    this.outgoingRemap,
    this.dip,
    this.dipShowsOutgoing = false,
    this.dipAmount = 0,
  });

  factory _TransitionShape.of(Transition transition, double p, OutputSpec target) {
    final xCount = target.xCount;
    final yCount = target.yCount;
    final panels = target.radioPanelsCount;
    switch (transition.kind) {
      case TransitionKind.crossfade:
        // The renderer keeps its scalar path for crossfades; this is the
        // same blend per pixel.
        return _TransitionShape(
          incomingPixels: List.filled(target.pixelsCount, p),
          incomingPanels: List.filled(panels, p),
        );
      case TransitionKind.dipToBlack:
      case TransitionKind.dipToWhite:
        final color = transition.kind == TransitionKind.dipToBlack ? Colors.black : Colors.white;
        return p < 0.5
            ? _TransitionShape(dip: color, dipShowsOutgoing: true, dipAmount: 2 * p)
            : _TransitionShape(dip: color, dipAmount: 2 * (1 - p));
      case TransitionKind.wipe:
        // u = where the edge reaches a pixel, 0 (first) … 1 (last).
        double ramp(double u) => ((p * (1 + wipeSoftness) - u) / wipeSoftness).clamp(0.0, 1.0);
        double alongX(double ux) => switch (transition.direction) {
              TransitionDirection.right => 1 - ux,
              TransitionDirection.center => (ux - 0.5).abs() * 2,
              _ => ux,
            };
        final pixels = List<double>.filled(target.pixelsCount, 0);
        for (var x = 0; x < xCount; x++) {
          for (var y = 0; y < yCount; y++) {
            final u = switch (transition.direction) {
              TransitionDirection.up => (y + 0.5) / yCount,
              TransitionDirection.down => 1 - (y + 0.5) / yCount,
              _ => alongX((x + 0.5) / xCount),
            };
            pixels[x * yCount + y] = ramp(u);
          }
        }
        final vertical =
            transition.direction == TransitionDirection.up || transition.direction == TransitionDirection.down;
        return _TransitionShape(
          incomingPixels: pixels,
          incomingPanels: [for (var i = 0; i < panels; i++) vertical ? p : ramp(alongX((i + 0.5) / panels))],
        );
      case TransitionKind.push:
        final pixels = List<double>.filled(target.pixelsCount, 0);
        final incoming = List<int>.filled(target.pixelsCount, -1);
        final outgoing = List<int>.filled(target.pixelsCount, -1);
        final vertical =
            transition.direction == TransitionDirection.up || transition.direction == TransitionDirection.down;
        final span = vertical ? yCount : xCount;
        final shift = (p * span).round().clamp(0, span);
        for (var x = 0; x < xCount; x++) {
          for (var y = 0; y < yCount; y++) {
            final at = vertical ? y : x;
            // The incoming clip enters from the direction's side, so the
            // destination coordinate `at` shows it at `inAt`, else the
            // outgoing clip at `outAt`.
            final bool showsIncoming;
            final int sourceAt;
            switch (transition.direction) {
              case TransitionDirection.right || TransitionDirection.down:
                showsIncoming = at >= span - shift;
                sourceAt = showsIncoming ? at - (span - shift) : at + shift;
              default:
                showsIncoming = at < shift;
                sourceAt = showsIncoming ? at - shift + span : at - shift;
            }
            final index = x * yCount + y;
            final source = vertical ? x * yCount + sourceAt : sourceAt * yCount + y;
            if (showsIncoming) {
              pixels[index] = 1;
              incoming[index] = source;
            } else {
              outgoing[index] = source;
            }
          }
        }
        return _TransitionShape(
          incomingPixels: pixels,
          incomingPanels: List.filled(panels, p),
          incomingRemap: incoming,
          outgoingRemap: outgoing,
        );
    }
  }
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
      final length = _sourceLength(clip, index);
      final sourceTime = clip.contains(time) ? clip.sourceTimeAt(time) : clip.extendedSourceTimeAt(time, length);
      final transition = inIntoWindow ? intoWindow.transition : (inOutWindow ? outWindow.transition : null);
      if (transition != null && transition.kind != TransitionKind.crossfade) {
        if (factor <= 0) continue;
        final window = inIntoWindow ? intoWindow : outWindow!;
        final p = window.progress(time);
        final shape = _TransitionShape.of(transition, p, composition.target);
        final at = _clampToLength(sourceTime, length);
        if (shape.dip case final dip?) {
          if (shape.dipShowsOutgoing == inIntoWindow) continue;
          layers.add(_Layer(clip, index, at, factor, overlay: dip, overlayAmount: shape.dipAmount));
        } else if (inIntoWindow) {
          layers.add(_Layer(clip, index, at, factor,
              pixelWeights: shape.incomingPixels, panelWeights: shape.incomingPanels, remap: shape.incomingRemap));
        } else {
          final next = track.clips[position + 1];
          final incoming =
              _usable(next) && (next.isEffect || _usableIndex(next) != null) ? _factor(track, next, time) : 0.0;
          double outgoing(double share) {
            final denominator = 1 - share * incoming;
            return denominator <= 1e-12 ? 0.0 : (1 - share) / denominator;
          }

          layers.add(_Layer(
            clip,
            index,
            at,
            factor,
            pixelWeights: [for (final share in shape.incomingPixels!) outgoing(share)],
            panelWeights: [for (final share in shape.incomingPanels!) outgoing(share)],
            remap: shape.outgoingRemap,
          ));
        }
        continue;
      }
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
      _composite(view.frame.pixels, pixels, layer.factor, clip.blend,
          from: from, to: to, included: mask?.contains, options: layer.pixelOptions);
    }
    if (region.coversRadioPanels) {
      for (final panel in view.radioPanels) {
        if (!region.affectsPanel(panel.index)) continue;
        _composite(panel.colors, panels[panel.index - 1], layer.panelFactor(panel.index - 1), clip.blend,
            included: mask == null ? null : (led) => mask.containsPanelPixel(panel.index, led),
            options: layer.panelOptions(panel.index - 1));
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
      _multiply(view.frame.pixels, pixels, layer.factor, clip.blend,
          from: from, to: to, included: mask?.contains, options: layer.pixelOptions);
    }
    if (region.coversRadioPanels) {
      for (final panel in view.radioPanels) {
        if (!region.affectsPanel(panel.index)) continue;
        _multiply(panel.colors, panels[panel.index - 1], layer.panelFactor(panel.index - 1), clip.blend,
            included: mask == null ? null : (led) => mask.containsPanelPixel(panel.index, led),
            options: layer.panelOptions(panel.index - 1));
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
    // An effect's output lines up with its input: a push does not shift it,
    // only the boundary between the two effects moves.
    final options = layer.pixelOptions;
    if (_columnSpan(region) case (final from, final to)) {
      _composite(output.frame.pixels, pixels, layer.factor, clip.blend,
          from: from,
          to: to,
          included: mask?.contains,
          options: _PixelOptions(options.weights, null, options.overlay, options.overlayAmount));
    }
    if (region.coversRadioPanels) {
      for (final panel in output.radioPanels) {
        if (!region.affectsPanel(panel.index)) continue;
        _composite(panel.colors, panels[panel.index - 1], layer.panelFactor(panel.index - 1), clip.blend,
            included: mask == null ? null : (led) => mask.containsPanelPixel(panel.index, led),
            options: layer.panelOptions(panel.index - 1));
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

  /// The source color shown at destination pixel [i] in a transition
  /// ([_PixelOptions.remap], then the overlay mixed in), or null for none.
  static Color? _transitionColor(List<Color> source, int i, _PixelOptions options) {
    final from = options.remap?[i] ?? i;
    if (from < 0 || from >= source.length) return null;
    final color = source[from];
    final overlay = options.overlay;
    if (overlay == null || options.overlayAmount <= 0) return color;
    return Color.alphaBlend(overlay.withAlpha((255 * options.overlayAmount.clamp(0.0, 1.0)).round()), color);
  }

  /// Composites `source[i]` over `destination[i]` for `i` in `[from, to)`
  /// (the whole list by default) where [included] (every pixel by default)
  /// allows it.
  ///
  /// With [options] (a transition), the factor is multiplied by
  /// `weights[i]`, the color is read from `source[remap[i]]` (nothing is
  /// drawn where it is `-1`) and the overlay is mixed into it first.
  static void _composite(List<Color> source, List<Color> destination, double factor, BlendMode blend,
      {int from = 0, int? to, bool Function(int index)? included, _PixelOptions options = _PixelOptions.none}) {
    final end = to ?? destination.length;
    if (!options.isNone) {
      for (var i = from; i < end; i++) {
        if (included != null && !included(i)) continue;
        final color = _transitionColor(source, i, options);
        if (color == null) continue;
        final scaled = _scaled(color, factor * (options.weights?[i] ?? 1));
        if (scaled == null) continue;
        destination[i] = Color.composite(scaled, destination[i], blend);
      }
      return;
    }
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
  ///
  /// With [options] see [_composite]; a pixel whose weight is 0 or that
  /// shows no source pixel is left unchanged (like a mask layer at factor
  /// 0, which is not applied at all).
  static void _multiply(List<Color> source, List<Color> destination, double factor, BlendMode blend,
      {int from = 0, int? to, bool Function(int index)? included, _PixelOptions options = _PixelOptions.none}) {
    final end = to ?? destination.length;
    for (var i = from; i < end; i++) {
      if (included != null && !included(i)) continue;
      final Color? scaled;
      if (options.isNone) {
        scaled = _scaled(source[i], factor);
      } else {
        final weight = options.weights?[i] ?? 1;
        final color = _transitionColor(source, i, options);
        if (color == null || weight <= 0) continue;
        scaled = _scaled(color, factor * weight);
      }
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

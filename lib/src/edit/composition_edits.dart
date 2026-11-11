import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_generators/icicles_generators.dart';

import '../model/audio_track.dart';
import '../model/clip.dart';
import '../model/clip_label.dart';
import '../model/composition.dart';
import '../model/loop_range.dart';
import '../model/macro_def.dart';
import '../model/marker.dart';
import '../model/output_spec.dart';
import '../model/region.dart';
import '../model/source_ref.dart';
import '../model/transition.dart';
import '../model/transition_fitting.dart';
import '../model/visual_track.dart';
import 'composition_exception.dart';
import 'source_info.dart';

/// The edge of a clip being dragged.
enum ClipEdge { start, end }

/// The edge of an audio segment being trimmed.
enum AudioEdge { start, end }

/// Song time at generator (or effect) time 0 of [clip] in [composition]:
/// `clip.start − clip.sourceIn − offset`, where `offset` is the mapping of
/// the audio segment at the clip start ([AudioTrack.offsetAt]: the segment
/// playing there, else the preceding one, else the first; 0 without a
/// soundtrack). What [ParametricRef.audioOrigin] holds when it is set.
Duration audioOriginFor(Composition composition, Clip clip) =>
    clip.start - clip.sourceIn - (composition.audio?.offsetAt(clip.start) ?? Duration.zero);

/// [composition] with every audio-bound generator or effect clip (a
/// [ParametricRef] whose `audioOrigin` is not `null`) re-anchored to
/// [audioOriginFor]; the same instance when nothing changes. Every edit
/// operation applies it.
Composition reanchorGeneratorClips(Composition composition) {
  var changed = false;
  final tracks = <VisualTrack>[];
  for (final track in composition.tracks) {
    var trackChanged = false;
    final clips = <Clip>[];
    for (final clip in track.clips) {
      final source = clip.source;
      if (source is ParametricRef && source.audioOrigin != null) {
        final origin = audioOriginFor(composition, clip);
        if (origin != source.audioOrigin) {
          clips.add(clip.copyWith(source: source.copyWith(audioOrigin: origin)));
          trackChanged = true;
          continue;
        }
      }
      clips.add(clip);
    }
    if (trackChanged) changed = true;
    tracks.add(trackChanged ? track.copyWith(clips: clips) : track);
  }
  return changed ? composition.copyWith(tracks: tracks) : composition;
}

/// Pure edit operations: each returns a new [Composition] or throws a
/// [CompositionException]; the receiver never changes.
///
/// Clips on one track never overlap: a move, trim or stretch that would
/// overlap a neighbour is clamped to the neighbour's edge. Transitions that
/// no longer join two adjacent clips are removed, and their length is
/// re-limited by [fitTransitions] after every change.
///
/// Generator and effect clips ([ParametricRef]) always play at speed 1 and
/// never loop; [setClipSpeed] and [setClipLoop] refuse to change that with
/// [CompositionErrorKind.invalidValue], and [setClipMask] refuses an effect
/// clip. Every operation keeps the `audioOrigin` of audio-bound generator
/// and effect clips in sync ([reanchorGeneratorClips]).
extension CompositionEdits on Composition {
  // ---------------------------------------------------------------- tracks

  /// Inserts [track] at [index] (default: on top).
  Composition addTrack(VisualTrack track, {int? index}) {
    if (trackById(track.id) != null) {
      throw CompositionException(CompositionErrorKind.duplicateId, 'Track id "${track.id}" is already used.');
    }
    for (final clip in track.clips) {
      _ensureClipIdFree(clip.id);
    }
    final tracks = [...this.tracks];
    tracks.insert((index ?? tracks.length).clamp(0, tracks.length), track);
    return _guard(() => reanchorGeneratorClips(copyWith(tracks: tracks)));
  }

  /// Removes the track and its clips.
  Composition removeTrack(String trackId) {
    _track(trackId);
    return copyWith(tracks: [
      for (final track in tracks)
        if (track.id != trackId) track
    ]);
  }

  /// Moves the track to [newIndex] (0 is the bottom).
  Composition reorderTrack(String trackId, int newIndex) {
    final track = _track(trackId);
    final tracks = [...this.tracks]..remove(track);
    tracks.insert(newIndex.clamp(0, tracks.length), track);
    return copyWith(tracks: tracks);
  }

  /// Changes track properties; [opacity] is clamped to `[0, 1]`.
  Composition updateTrack(
    String trackId, {
    String? name,
    bool? muted,
    bool? solo,
    bool? locked,
    double? opacity,
  }) {
    final track = _track(trackId);
    return _replaceTrack(track.copyWith(
      name: name,
      muted: muted,
      solo: solo,
      locked: locked,
      opacity: opacity == null ? null : _unit(opacity, 'opacity'),
    ));
  }

  // ----------------------------------------------------------------- clips

  /// Adds [clip] to the track.
  ///
  /// An indexed clip (a file, image, drawing or nested composition,
  /// [SourceRef.isIndexed]) needs the [source] info: the source must have
  /// the layout of [target] ([CompositionErrorKind.layoutMismatch]
  /// otherwise) and the trim is clamped to the source length. A generator
  /// or effect clip ([ParametricRef]) needs none — they render at the
  /// target layout — and its trim is clamped to the ref's length. The clip
  /// is placed in the free gap nearest to its start that fits it.
  Composition addClip(String trackId, Clip clip, [SourceInfo? source]) {
    final track = _unlockedTrack(trackId);
    _ensureClipIdFree(clip.id);
    final sourceLength = _sourceLengthOf(clip.source, source);
    if (clip.sourceIn >= sourceLength) {
      throw CompositionException(
        CompositionErrorKind.invalidValue,
        'sourceIn ${clip.sourceIn} is not before the source end $sourceLength.',
      );
    }
    var added = clip;
    if (clip.sourceOut > sourceLength) {
      added = _guard(() => clip.copyWith(sourceOut: sourceLength));
    }
    final start = _placeInGap(track.clips, added.start, added.duration);
    return _replaceClips(track, [...track.clips, added.copyWith(start: start)]);
  }

  /// One pass of [source]: the ref's length for a parametric source, else
  /// the [info]'s duration, which must be given and of the target layout.
  Duration _sourceLengthOf(SourceRef source, SourceInfo? info) {
    if (source case ParametricRef(:final length)) return length;
    if (info == null) {
      throw CompositionException(CompositionErrorKind.invalidValue, 'Source "${source.label}" needs its SourceInfo.');
    }
    if (!target.acceptsLayoutOf(info.header)) {
      final header = info.header;
      throw CompositionException(
        CompositionErrorKind.layoutMismatch,
        'Source "${source.label}" is ${header.xCount}x${header.yCount} with ${header.radioPanelsCount} radio '
        'panels of ${header.radioPanelPixelCount} pixels, the target is ${target.xCount}x${target.yCount} with '
        '${target.radioPanelsCount} radio panels of ${target.radioPanelPixelCount} pixels.',
      );
    }
    return info.duration;
  }

  /// Replaces the source of the clip by [source] (an edited drawing, an
  /// image with other options, a re-imported file): an indexed source
  /// needs its [info] (checked against the target like [addClip]). The
  /// trim is kept where it fits the new length and clamped otherwise (a
  /// `sourceIn` beyond the end restarts at 0); the clip's end moves with
  /// the trim, stopped at the next clip. A parametric source may only be
  /// replaced by one of the same kind (`invalidValue`).
  Composition setClipSource(String clipId, SourceRef source, [SourceInfo? info]) {
    final (:track, :clip) = _editableClip(clipId);
    if (clip.source.isIndexed != source.isIndexed) {
      throw CompositionException(
          CompositionErrorKind.invalidValue, 'Clip "$clipId" cannot change between indexed and parametric sources.');
    }
    final length = _sourceLengthOf(source, info);
    var sourceIn = clip.sourceIn;
    var sourceOut = clip.sourceOut;
    if (sourceIn >= length) {
      sourceIn = Duration.zero;
      sourceOut = length;
    } else if (sourceOut > length) {
      sourceOut = length;
    }
    var updated = _guard(() => clip.copyWith(source: source, sourceIn: sourceIn, sourceOut: sourceOut));
    final upper = _bounds(track, clip).upper;
    if (upper != null && updated.end > upper) {
      updated = _stretch(updated, ClipEdge.end, upper, _bounds(track, clip));
    }
    return _replaceClips(track, [for (final other in track.clips) other.id == clipId ? updated : other]);
  }

  /// Replaces the parameter bindings of a generator or effect clip
  /// ([CompositionErrorKind.invalidValue] for a file clip).
  ///
  /// [audioBound] sets whether the program reads the audio clock: `true`
  /// anchors `audioOrigin` at [audioOriginFor], `false` clears it, `null`
  /// (default) keeps the current state.
  Composition setGeneratorBindings(String clipId, Map<String, ParamBinding> bindings, {bool? audioBound}) =>
      _updateParametric(clipId, (source) {
        var updated = source.copyWith(bindings: bindings);
        if (audioBound == false) updated = updated.copyWith(removeAudioOrigin: true);
        if (audioBound == true && updated.audioOrigin == null) updated = updated.copyWith(audioOrigin: Duration.zero);
        return updated;
      });

  /// [setGeneratorBindings] for an effect clip (the same operation).
  Composition setEffectBindings(String clipId, Map<String, ParamBinding> bindings, {bool? audioBound}) =>
      setGeneratorBindings(clipId, bindings, audioBound: audioBound);

  /// Changes the seed of a generator or effect clip
  /// ([CompositionErrorKind.invalidValue] for a file clip).
  Composition setGeneratorSeed(String clipId, int seed) =>
      _updateParametric(clipId, (source) => source.copyWith(seed: seed));

  /// [setGeneratorSeed] for an effect clip (the same operation).
  Composition setEffectSeed(String clipId, int seed) => setGeneratorSeed(clipId, seed);

  Composition _updateParametric(String clipId, ParametricRef Function(ParametricRef source) update) {
    final (:track, :clip) = _editableClip(clipId);
    final source = clip.source;
    if (source is! ParametricRef) {
      throw CompositionException(
          CompositionErrorKind.invalidValue, 'Clip "$clipId" is not a generator or effect clip.');
    }
    final updated = _guard(() => clip.copyWith(source: update(source)));
    return _replaceClips(track, [for (final other in track.clips) other.id == clipId ? updated : other]);
  }

  /// Moves the clip to [start], optionally onto the track [toTrackId].
  ///
  /// The clip lands in the free gap of the target track nearest to [start]
  /// that fits it, so an overlap is clamped to the neighbour's edge and the
  /// start never becomes negative.
  Composition moveClip(String clipId, Duration start, {String? toTrackId}) {
    final (:track, :clip) = _editableClip(clipId);
    final destination = toTrackId == null || toTrackId == track.id ? track : _unlockedTrack(toTrackId);
    final others = [
      for (final other in destination.clips)
        if (other.id != clipId) other
    ];
    final moved = clip.copyWith(start: _placeInGap(others, start, clip.duration));
    if (identical(destination, track)) return _replaceClips(track, [...others, moved]);
    final source = _replaceClips(track, [
      for (final other in track.clips)
        if (other.id != clipId) other
    ]);
    return source._replaceClips(source._track(destination.id), [...others, moved]);
  }

  /// Splits the clip at timeline time [at] into two clips: the left one
  /// keeps the id, the right one gets [newClipId]. The left part keeps the
  /// fade in, the right part the fade out and the outgoing transition.
  ///
  /// The two parts cover the original span (within the 1 µs rounding of
  /// the derived durations, never overlapping). For a looping clip split
  /// inside a pass, the right part continues that pass exactly when it ends
  /// within it; otherwise it restarts the loop at `sourceIn`.
  Composition splitClip(String clipId, Duration at, {required String newClipId}) {
    final (:track, :clip) = _editableClip(clipId);
    _ensureClipIdFree(newClipId);
    if (at < clip.start + Clip.minDuration || at > clip.end - Clip.minDuration) {
      throw CompositionException(
        CompositionErrorKind.invalidSplit,
        'Split point $at is not inside clip "$clipId" (${clip.start} – ${clip.end}).',
      );
    }
    final (left, right) = clip.isLooping ? _splitLoop(clip, at, newClipId) : _splitOnce(clip, at, newClipId);
    final clips = [
      for (final other in track.clips)
        if (other.id != clipId) other,
      left,
      right
    ];
    final transitions = [
      for (final transition in track.transitions)
        if (transition.fromClipId == clipId)
          Transition(
            id: transition.id,
            fromClipId: newClipId,
            toClipId: transition.toClipId,
            duration: transition.duration,
            alignment: transition.alignment,
          )
        else
          transition,
    ];
    return _replaceClips(track, clips, transitions: transitions);
  }

  /// Removes the clip and its transitions.
  Composition removeClip(String clipId) {
    final (:track, clip: _) = _editableClip(clipId);
    return _replaceClips(track, [
      for (final other in track.clips)
        if (other.id != clipId) other
    ]);
  }

  /// Copies the clip as [newClipId] onto [toTrackId] (default: its track)
  /// at [start] (default: right after the original), placed like
  /// [moveClip]. Transitions are not copied.
  Composition duplicateClip(String clipId, {required String newClipId, Duration? start, String? toTrackId}) {
    final (:track, :clip) = _editableClip(clipId);
    _ensureClipIdFree(newClipId);
    final destination = toTrackId == null ? track : _unlockedTrack(toTrackId);
    final copyStart = _placeInGap(destination.clips, start ?? clip.end, clip.duration);
    return _replaceClips(destination, [...destination.clips, clip.copyWith(id: newClipId, start: copyStart)]);
  }

  /// Changes the look of the clip. [opacity] is clamped to `[0, 1]`, fades
  /// to `[0, duration]`; [isMask] turns the clip into a track matte (see
  /// [Clip.isMask]); [reverse] plays it backwards; [pingPong] alternates the
  /// direction of a looping clip ([CompositionErrorKind.invalidValue] for a
  /// clip that does not loop); [label] colors it on the timeline.
  Composition setClipProps(
    String clipId, {
    BlendMode? blend,
    double? opacity,
    Duration? fadeIn,
    Duration? fadeOut,
    Region? region,
    bool? isMask,
    bool? reverse,
    bool? pingPong,
    ClipLabel? label,
  }) {
    final (:track, :clip) = _editableClip(clipId);
    final updated = _withProps(
      clip,
      blend: blend,
      opacity: opacity,
      fadeIn: fadeIn,
      fadeOut: fadeOut,
      region: region,
      isMask: isMask,
      reverse: reverse,
      pingPong: pingPong,
      label: label,
    );
    return _replaceClips(track, [for (final other in track.clips) other.id == clipId ? updated : other]);
  }

  /// Makes the clip a mask layer ([Clip.isMask]) or a normal clip again;
  /// [CompositionErrorKind.invalidValue] for an effect clip.
  Composition setClipMask(String clipId, bool isMask) => setClipProps(clipId, isMask: isMask);

  /// Plays the clip backwards or forwards again ([Clip.reverse]).
  Composition setClipReverse(String clipId, bool reverse) => setClipProps(clipId, reverse: reverse);

  /// Alternates the direction of a looping clip on every pass
  /// ([Clip.pingPong]); [CompositionErrorKind.invalidValue] for a clip that
  /// does not loop.
  Composition setClipPingPong(String clipId, bool pingPong) => setClipProps(clipId, pingPong: pingPong);

  /// Colors the clip on the timeline ([Clip.label]).
  Composition setClipLabel(String clipId, ClipLabel label) => setClipProps(clipId, label: label);

  // ------------------------------------------------------- several clips

  /// Moves the clips [clipIds] together by [delta] (and [trackShift] tracks
  /// up, negative = down), keeping their relative positions: one step, all
  /// or nothing.
  ///
  /// [delta] is clamped so that no clip starts before the timeline start
  /// and [trackShift] so that every clip stays on an existing track. Clips
  /// that would then overlap a clip that is not moved are refused with
  /// [CompositionErrorKind.overlap]; a locked source or destination track
  /// with [CompositionErrorKind.trackLocked]. Transitions between two moved
  /// clips that stay adjacent are kept.
  Composition moveClips(Iterable<String> clipIds, Duration delta, {int trackShift = 0}) {
    final ids = clipIds.toSet();
    if (ids.isEmpty) return this;
    final moved = [for (final id in ids) _editableClip(id)];
    var shift = delta;
    var trackStep = trackShift;
    for (final (:track, :clip) in moved) {
      if (clip.start + shift < Duration.zero) shift = -clip.start;
      final index = tracks.indexOf(track);
      if (index + trackStep < 0) trackStep = -index;
      if (index + trackStep >= tracks.length) trackStep = tracks.length - 1 - index;
    }
    if (shift == Duration.zero && trackStep == 0) return this;
    // Clips grouped by their destination track, with the ones that stay.
    final destinations = <String, List<Clip>>{};
    final transitions = <String, List<Transition>>{};
    for (final track in tracks) {
      destinations[track.id] = [
        for (final clip in track.clips)
          if (!ids.contains(clip.id)) clip
      ];
      transitions[track.id] = [];
    }
    for (final (:track, :clip) in moved) {
      final destination = tracks[tracks.indexOf(track) + trackStep];
      if (destination.locked) {
        throw CompositionException(CompositionErrorKind.trackLocked, 'Track "${destination.id}" is locked.');
      }
      destinations[destination.id]!.add(clip.copyWith(start: clip.start + shift));
      for (final transition in track.transitions) {
        if (transition.fromClipId == clip.id && ids.contains(transition.toClipId)) {
          transitions[destination.id]!.add(transition);
        }
      }
    }
    final updated = <VisualTrack>[];
    for (final track in tracks) {
      final clips = destinations[track.id]!..sort((a, b) => a.start.compareTo(b.start));
      _ensureNoOverlap(clips, track.id);
      final kept = [
        for (final transition in track.transitions)
          if (!ids.contains(transition.fromClipId) && !ids.contains(transition.toClipId)) transition,
        ...transitions[track.id]!,
      ];
      updated.add(track.copyWith(clips: clips, transitions: fitTransitions(clips, kept).kept));
    }
    return _guard(() => reanchorGeneratorClips(copyWith(tracks: updated)));
  }

  /// [moveClips] by [delta] on the same tracks (the arrow-key nudge).
  Composition nudgeClips(Iterable<String> clipIds, Duration delta) => moveClips(clipIds, delta);

  /// Removes the clips (and their transitions) in one step; a locked track
  /// or an unknown id refuses the whole operation.
  Composition removeClips(Iterable<String> clipIds) {
    final ids = clipIds.toSet();
    if (ids.isEmpty) return this;
    final placed = [for (final id in ids) _editableClip(id)];
    var result = this;
    for (final track in {for (final (:track, clip: _) in placed) track.id}) {
      final current = result._track(track);
      result = result._replaceClips(current, [
        for (final clip in current.clips)
          if (!ids.contains(clip.id)) clip
      ]);
    }
    return result;
  }

  /// Removes the clip and closes the gap it leaves: every later clip of its
  /// track moves left by the clip's duration (transitions between them are
  /// kept).
  Composition rippleDelete(String clipId) {
    final (:track, :clip) = _editableClip(clipId);
    final shift = clip.duration;
    final clips = [
      for (final other in track.clips)
        if (other.id != clipId) other.start >= clip.end ? other.copyWith(start: other.start - shift) : other
    ];
    return _replaceClips(track, clips);
  }

  /// Pastes copies of [templates] onto [trackId] from [at] (clamped to the
  /// timeline start), keeping their relative offsets, under the fresh
  /// [newClipIds] (one per template). Transitions are not pasted. Copies
  /// that would overlap the track's clips (or each other) are refused with
  /// [CompositionErrorKind.overlap]; a generator template keeps its
  /// bindings and is re-anchored to the audio when audio-bound.
  Composition pasteClips(
    List<Clip> templates,
    Duration at,
    String trackId, {
    required List<String> newClipIds,
  }) {
    if (templates.isEmpty) return this;
    if (newClipIds.length != templates.length) {
      throw CompositionException(
        CompositionErrorKind.invalidValue,
        '${newClipIds.length} ids given for ${templates.length} clips.',
      );
    }
    final track = _unlockedTrack(trackId);
    final seen = <String>{};
    for (final id in newClipIds) {
      _ensureClipIdFree(id);
      if (!seen.add(id)) throw CompositionException(CompositionErrorKind.duplicateId, 'Clip id "$id" is repeated.');
    }
    final origin = templates.map((clip) => clip.start).reduce((a, b) => a < b ? a : b);
    final from = at.isNegative ? Duration.zero : at;
    final pasted = [
      for (final (index, template) in templates.indexed)
        template.copyWith(id: newClipIds[index], start: from + (template.start - origin)),
    ];
    final clips = [...track.clips, ...pasted]..sort((a, b) => a.start.compareTo(b.start));
    _ensureNoOverlap(clips, track.id);
    return _replaceClips(track, clips);
  }

  /// Copies the look of [from] onto the clips [targetIds] in one step
  /// (Premiere's paste attributes): [blend], [opacity], the [fades] (clamped
  /// to each target's duration), the [region] (fitted to the target
  /// layout), [isMask] (skipped for effect clips), [label] and, for a
  /// generator (effect) target of the same generator (effect) as [from],
  /// its parameter bindings ([params]); the target keeps its seed and
  /// length and follows the template's audio binding.
  /// A locked track or an unknown id refuses the whole operation.
  Composition applyAttributes(
    Iterable<String> targetIds,
    Clip from, {
    bool blend = true,
    bool opacity = true,
    bool fades = true,
    bool region = true,
    bool isMask = true,
    bool params = true,
    bool label = false,
  }) {
    final ids = targetIds.toSet()..remove(from.id);
    if (ids.isEmpty) return this;
    final placed = [for (final id in ids) _editableClip(id)];
    final fromSource = from.source;
    final replacements = <String, Clip>{};
    for (final (track: _, :clip) in placed) {
      var updated = _withProps(
        clip,
        blend: blend ? from.blend : null,
        opacity: opacity ? from.opacity : null,
        fadeIn: fades ? from.fadeIn : null,
        fadeOut: fades ? from.fadeOut : null,
        region: region ? from.region.normalized(target) : null,
        // An effect clip is never a mask; the attribute is skipped for it.
        isMask: isMask && !clip.isEffect ? from.isMask : null,
        label: label ? from.label : null,
      );
      final source = updated.source;
      if (params && fromSource is ParametricRef && source is ParametricRef) {
        if (fromSource.runtimeType == source.runtimeType && fromSource.programId == source.programId) {
          var copied = switch (source) {
            GeneratorRef() =>
              source.copyWith(bindings: fromSource.bindings, generatorVersion: fromSource.programVersion),
            EffectRef() => source.copyWith(bindings: fromSource.bindings, effectVersion: fromSource.programVersion),
          };
          copied = fromSource.usesAudio
              ? copied.copyWith(audioOrigin: copied.audioOrigin ?? Duration.zero)
              : copied.copyWith(removeAudioOrigin: true);
          updated = _guard(() => updated.copyWith(source: copied));
        }
      }
      replacements[clip.id] = updated;
    }
    return _guard(() => reanchorGeneratorClips(copyWith(tracks: [
          for (final track in tracks)
            track.copyWith(clips: [for (final clip in track.clips) replacements[clip.id] ?? clip]),
        ])));
  }

  /// Drags an edge of the clip to timeline time [to].
  ///
  /// - Plain drag of a clip that does not loop trims: the edge moves
  ///   `sourceIn`/`sourceOut`, clamped to `[0, sourceDuration]`.
  /// - Plain drag of a looping clip: the end edge sets `loopDuration` (more
  ///   or fewer repetitions) and keeps the trim; the start edge trims
  ///   `sourceIn` and keeps the clip end fixed.
  /// - [stretch] (Shift + drag) changes `speed` and keeps the trim; a
  ///   looping clip scales `loopDuration` by the same factor.
  ///
  /// Dragging the start edge keeps the end fixed and vice versa. The edge
  /// stops at the neighbours, at the timeline start and at
  /// [Clip.minDuration]; [sourceDuration] is the length of one source pass.
  ///
  /// A generator or effect clip is always trimmed ([stretch] is ignored):
  /// the end edge grows or shrinks the ref's length together with
  /// `sourceOut` (at most [maxBakeLength]; [sourceDuration] is ignored), the
  /// start edge trims `sourceIn`.
  Composition dragClipEdge(
    String clipId,
    ClipEdge edge,
    Duration to, {
    required Duration sourceDuration,
    bool stretch = false,
  }) {
    final (:track, :clip) = _editableClip(clipId);
    final bounds = _bounds(track, clip);
    final Clip updated;
    if (clip.isParametric) {
      updated = _dragGeneratorEdge(clip, edge, to, bounds);
    } else if (stretch) {
      updated = _stretch(clip, edge, to, bounds);
    } else if (clip.isLooping) {
      updated = _dragLoopEdge(clip, edge, to, bounds);
    } else {
      updated = _trim(clip, edge, to, bounds, sourceDuration);
    }
    return _replaceClips(track, [for (final other in track.clips) other.id == clipId ? updated : other]);
  }

  /// Sets the playback [speed] (clamped to the allowed range), keeping the
  /// start and the trim; a looping clip scales `loopDuration`. When the
  /// longer clip would overlap the next one, the speed is raised just enough
  /// to end at its start.
  Composition setClipSpeed(String clipId, double speed) {
    final (:track, :clip) = _editableClip(clipId);
    if (!speed.isFinite) throw CompositionException(CompositionErrorKind.invalidValue, 'Speed $speed is not finite.');
    final newSpeed = speed.clamp(Clip.minSpeed, Clip.maxSpeed).toDouble();
    if (clip.isParametric) {
      if (newSpeed == 1.0) return this;
      throw CompositionException(
          CompositionErrorKind.invalidValue, 'Generator or effect clip "$clipId" always plays at speed 1.');
    }
    final loop = clip.loopDuration;
    var updated = _guard(() => clip.copyWith(
          speed: newSpeed,
          loopDuration: loop == null ? null : _scaled(loop, clip.speed / newSpeed),
        ));
    final upper = _bounds(track, clip).upper;
    if (upper != null && updated.end > upper) {
      updated = _stretch(clip, ClipEdge.end, upper, _bounds(track, clip));
    }
    return _replaceClips(track, [for (final other in track.clips) other.id == clipId ? updated : other]);
  }

  /// The inspector "Loop" toggle: on sets `loopDuration` to the current
  /// duration, off removes the loop and clamps the clip to one pass (a loop
  /// shorter than one pass becomes the same trim, so the clip looks the
  /// same).
  Composition setClipLoop(String clipId, {required bool enabled}) {
    final (:track, :clip) = _editableClip(clipId);
    final loop = clip.loopDuration;
    final Clip updated;
    if (clip.isParametric && enabled) {
      throw CompositionException(CompositionErrorKind.invalidValue, 'Generator or effect clip "$clipId" cannot loop.');
    }
    if (enabled) {
      updated = loop != null ? clip : clip.copyWith(loopDuration: clip.duration);
    } else if (loop == null) {
      updated = clip;
    } else if (loop < clip.passDuration) {
      final range = _rangeWithin(loop, clip.speed).clamp(1, clip.sourceRange.inMicroseconds);
      updated = _guard(() => clip.copyWith(removeLoop: true, sourceOut: clip.sourceIn + _us(range)));
    } else {
      updated = clip.copyWith(removeLoop: true);
    }
    return _replaceClips(track, [for (final other in track.clips) other.id == clipId ? updated : other]);
  }

  // ----------------------------------------------------------- transitions

  /// Adds a crossfade between two adjacent clips of one track; its duration
  /// is clamped to the limit of [fitTransitions].
  Composition addTransition(Transition transition) {
    final placed = findClip(transition.fromClipId);
    if (placed == null) {
      throw CompositionException(CompositionErrorKind.clipNotFound, 'Clip "${transition.fromClipId}" not found.');
    }
    final track = placed.track;
    if (findClip(transition.toClipId) == null) {
      throw CompositionException(CompositionErrorKind.clipNotFound, 'Clip "${transition.toClipId}" not found.');
    }
    if (track.locked) throw CompositionException(CompositionErrorKind.trackLocked, 'Track "${track.id}" is locked.');
    if (_findTransition(transition.id) != null) {
      throw CompositionException(CompositionErrorKind.duplicateId, 'Transition id "${transition.id}" is already used.');
    }
    if (track.transitionOutOf(transition.fromClipId) != null) {
      throw CompositionException(
        CompositionErrorKind.duplicateId,
        'Clip "${transition.fromClipId}" already has an outgoing transition.',
      );
    }
    final fitted = fitTransitions(track.clips, [...track.transitions, transition]);
    for (final issue in fitted.issues) {
      if (issue.transition != transition || !issue.dropped) continue;
      throw CompositionException(
          switch (issue.kind) {
            TransitionIssueKind.noRoom => CompositionErrorKind.noRoom,
            TransitionIssueKind.duplicate => CompositionErrorKind.duplicateId,
            TransitionIssueKind.missingClip || TransitionIssueKind.notAdjacent => CompositionErrorKind.notAdjacent,
            TransitionIssueKind.clamped => CompositionErrorKind.invalidValue,
          },
          'Transition "${transition.id}" does not fit: ${issue.kind.name}.');
    }
    return _replaceTrack(track.copyWith(transitions: fitted.kept));
  }

  /// Changes a transition; the duration is clamped like in [addTransition].
  Composition updateTransition(String transitionId, {Duration? duration, TransitionAlignment? alignment}) {
    final (track, transition) = _transition(transitionId);
    if (track.locked) throw CompositionException(CompositionErrorKind.trackLocked, 'Track "${track.id}" is locked.');
    final updated = _guard(() => transition.copyWith(duration: duration, alignment: alignment));
    return _replaceClips(track, track.clips, transitions: [
      for (final other in track.transitions) other.id == transitionId ? updated : other,
    ]);
  }

  Composition removeTransition(String transitionId) {
    final (track, _) = _transition(transitionId);
    if (track.locked) throw CompositionException(CompositionErrorKind.trackLocked, 'Track "${track.id}" is locked.');
    return _replaceTrack(track.copyWith(transitions: [
      for (final other in track.transitions)
        if (other.id != transitionId) other,
    ]));
  }

  // ------------------------------------------------------ markers, audio, tempo

  Composition addMarker(Marker marker) {
    if (markerById(marker.id) != null) {
      throw CompositionException(CompositionErrorKind.duplicateId, 'Marker id "${marker.id}" is already used.');
    }
    return copyWith(markers: [...markers, marker]);
  }

  /// Moves (negative times clamp to 0), renames or recolors a marker.
  Composition updateMarker(String markerId, {Duration? at, String? label, ClipLabel? color}) {
    final marker = _marker(markerId);
    final updated = marker.copyWith(at: at == null || !at.isNegative ? at : Duration.zero, label: label, color: color);
    return copyWith(markers: [for (final other in markers) other.id == markerId ? updated : other]);
  }

  /// Moves a marker to [at] (negative times clamp to 0).
  Composition moveMarker(String markerId, Duration at) => updateMarker(markerId, at: at);

  /// Sets or (with `null`) removes the in/out points.
  Composition setLoopRange(LoopRange? range) =>
      range == null ? copyWith(removeLoopRange: true) : copyWith(loopRange: range);

  Composition removeMarker(String markerId) {
    _marker(markerId);
    return copyWith(markers: [
      for (final other in markers)
        if (other.id != markerId) other
    ]);
  }

  // ---------------------------------------------------------------- macros

  /// Adds a macro ([CompositionErrorKind.duplicateId] when its id is used).
  Composition addMacro(MacroDef macro) {
    if (macroById(macro.id) != null) {
      throw CompositionException(CompositionErrorKind.duplicateId, 'Macro id "${macro.id}" is already used.');
    }
    return copyWith(macros: [...macros, macro]);
  }

  /// Renames a macro or changes the range / default of a number macro (the
  /// binding is re-salvaged against the new range).
  /// [CompositionErrorKind.macroNotFound], `invalidValue` for a bad range.
  Composition updateMacro(String macroId, {String? name, double? min, double? max, Object? defaultValue}) {
    final macro = _macro(macroId);
    final updated = _guard(() => macro.copyWith(name: name, min: min, max: max, defaultValue: defaultValue));
    return copyWith(macros: [for (final other in macros) other.id == macroId ? updated : other]);
  }

  /// Replaces the binding of a macro (made valid for the macro's [MacroDef.spec]).
  /// [CompositionErrorKind.macroNotFound].
  Composition setMacroBinding(String macroId, ParamBinding binding) {
    final macro = _macro(macroId);
    final updated = _guard(() => macro.copyWith(binding: binding));
    return copyWith(macros: [for (final other in macros) other.id == macroId ? updated : other]);
  }

  /// Removes a macro; parameters reading it keep their `MacroBinding` and
  /// fall back to their default (see `icicles_generators`).
  /// [CompositionErrorKind.macroNotFound].
  Composition removeMacro(String macroId) {
    _macro(macroId);
    return copyWith(macros: [
      for (final other in macros)
        if (other.id != macroId) other,
    ]);
  }

  /// Sets or (with `null`) removes the music track; audio-bound generator
  /// clips are re-anchored to the new mapping (0 without a soundtrack).
  Composition setAudio(AudioTrack? audio) =>
      reanchorGeneratorClips(audio == null ? copyWith(removeAudio: true) : copyWith(audio: audio));

  /// Moves every audio segment together so that the first one's
  /// [AudioSegment.offset] becomes [offset] (a negative offset skips the
  /// beginning of the file: the first segment's `sourceIn` grows instead and
  /// the following segments keep their distance to it, clamped at the
  /// timeline start). [CompositionErrorKind.invalidValue] without a
  /// soundtrack.
  Composition setAudioOffset(Duration offset) {
    final audio = _audio();
    final first = audio.first;
    final shift = offset - first.offset;
    final segments = <AudioSegment>[];
    for (final segment in audio.segments) {
      var start = segment.start + shift;
      var sourceIn = segment.sourceIn;
      final sourceOut = segment.sourceOut;
      if (start.isNegative) {
        // The part before the timeline start is skipped.
        sourceIn -= start;
        start = Duration.zero;
        if (sourceOut != null && sourceOut - sourceIn < AudioSegment.minDuration) continue;
      }
      segments.add(segment.copyWith(start: start, sourceIn: sourceIn));
    }
    if (segments.isEmpty) {
      throw const CompositionException(CompositionErrorKind.invalidValue, 'Every audio segment would fall before 0.');
    }
    return setAudio(_guard(() => audio.copyWith(segments: segments)));
  }

  /// Sets the soundtrack volume (clamped to `[0, AudioTrack.maxGain]`);
  /// [CompositionErrorKind.invalidValue] without a soundtrack.
  Composition setAudioGain(double gain) {
    final audio = _audio();
    if (!gain.isFinite) throw CompositionException(CompositionErrorKind.invalidValue, 'Gain $gain is not finite.');
    return copyWith(audio: audio.copyWith(gain: gain.clamp(0.0, AudioTrack.maxGain).toDouble()));
  }

  /// Splits the audio segment playing at timeline [at] in two: the left
  /// part keeps its id, the right one gets [newSegmentId] and continues
  /// the file where the left one stops (an open-ended segment leaves its
  /// right part open-ended). [sourceLength] bounds an open-ended segment.
  /// [CompositionErrorKind.invalidSplit] when no segment plays at [at] or
  /// a part would be shorter than [AudioSegment.minDuration].
  Composition splitAudio(Duration at, {required String newSegmentId, Duration? sourceLength}) {
    final audio = _audio();
    if (audio.segmentById(newSegmentId) != null) {
      throw CompositionException(CompositionErrorKind.duplicateId, 'Audio segment id "$newSegmentId" is already used.');
    }
    final segment = audio.segmentAt(at, sourceLength: sourceLength);
    final end = segment == null ? null : (sourceLength == null ? segment.end : segment.endFor(sourceLength));
    if (segment == null ||
        at < segment.start + AudioSegment.minDuration ||
        (end != null && at > end - AudioSegment.minDuration)) {
      throw CompositionException(CompositionErrorKind.invalidSplit, 'Split point $at is not inside an audio segment.');
    }
    final cut = segment.sourceIn + (at - segment.start);
    final left = segment.copyWith(sourceOut: cut);
    final right = segment.copyWith(id: newSegmentId, start: at, sourceIn: cut);
    return setAudio(_guard(() => audio.copyWith(segments: [
          for (final other in audio.segments)
            if (other.id != segment.id) other,
          left,
          right,
        ])));
  }

  /// Moves the audio segment to timeline [start]: it lands in the free gap
  /// between the other segments nearest to [start] that fits it, so it
  /// never overlaps and never starts before 0. An open-ended segment is as
  /// long as the rest of the file ([sourceLength]), unbounded without it.
  Composition moveAudioSegment(String segmentId, Duration start, {Duration? sourceLength}) {
    final audio = _audio();
    final segment = _audioSegment(audio, segmentId);
    final others = [
      for (final other in audio.segments)
        if (other.id != segmentId) other,
    ];
    final length = sourceLength == null ? segment.duration : segment.endFor(sourceLength) - segment.start;
    final placed = _placeAudioInGap(others, start, length, sourceLength);
    if (placed == null) return this;
    return setAudio(_guard(() => audio.copyWith(segments: [...others, segment.copyWith(start: placed)])));
  }

  /// Moves [edge] of the audio segment by [delta] (timeline time): the
  /// start edge trims `sourceIn` (the end stays), the end edge trims
  /// `sourceOut` (the start stays), each stopped at the file bounds, at the
  /// neighbouring segments, at the timeline start and at
  /// [AudioSegment.minDuration]. The end edge of an open-ended segment needs
  /// [sourceLength] ([CompositionErrorKind.invalidValue] otherwise); an end
  /// landing on the file end leaves the segment open-ended.
  Composition trimAudioSegment(String segmentId, AudioEdge edge, Duration delta, {Duration? sourceLength}) {
    final audio = _audio();
    final segment = _audioSegment(audio, segmentId);
    final index = audio.segments.indexOf(segment);
    final previous = index > 0 ? audio.segments[index - 1] : null;
    final next = index + 1 < audio.segments.length ? audio.segments[index + 1] : null;
    final AudioSegment updated;
    switch (edge) {
      case AudioEdge.start:
        final end = sourceLength == null ? segment.end : segment.endFor(sourceLength);
        var start = segment.start + delta;
        final lower = _maxDuration(previous == null ? Duration.zero : previous.end ?? Duration.zero, Duration.zero);
        // Never before the file start: the source in is start − offset.
        if (start < segment.offset) start = segment.offset;
        if (start < lower) start = lower;
        if (end != null && start > end - AudioSegment.minDuration) start = end - AudioSegment.minDuration;
        if (start < Duration.zero) start = Duration.zero;
        updated = segment.copyWith(start: start, sourceIn: segment.sourceIn + (start - segment.start));
      case AudioEdge.end:
        final current = segment.sourceOut ?? sourceLength;
        if (current == null) {
          throw const CompositionException(
              CompositionErrorKind.invalidValue, 'The end of an open-ended audio segment needs the file length.');
        }
        var sourceOut = current + delta;
        final minimum = segment.sourceIn + AudioSegment.minDuration;
        if (sourceOut < minimum) sourceOut = minimum;
        if (sourceLength != null && sourceOut > sourceLength) sourceOut = sourceLength;
        if (next != null) {
          final room = next.start - segment.start + segment.sourceIn;
          if (sourceOut > room) sourceOut = room;
        }
        updated = sourceLength != null && sourceOut >= sourceLength
            ? segment.copyWith(openEnded: true)
            : segment.copyWith(sourceOut: sourceOut);
    }
    if (updated == segment) return this;
    return setAudio(_guard(() => audio.copyWith(segments: [
          for (final other in audio.segments) other.id == segmentId ? updated : other,
        ])));
  }

  /// Removes the audio segment; removing the last one removes the track.
  Composition removeAudioSegment(String segmentId) {
    final audio = _audio();
    _audioSegment(audio, segmentId);
    if (audio.segments.length == 1) return setAudio(null);
    return setAudio(audio.copyWith(segments: [
      for (final other in audio.segments)
        if (other.id != segmentId) other,
    ]));
  }

  // ------------------------------------------------------ project settings

  /// Changes the output layout, keeping every clip: file clips of another
  /// layout are left for the application to report, generator and effect
  /// clips render at the new target, and the clip regions (pixel masks
  /// included) are fitted to it ([Region.normalized]).
  Composition setTarget(OutputSpec target) {
    if (target == this.target) return this;
    return copyWith(
      target: target,
      tracks: [
        for (final track in tracks)
          track.copyWith(clips: [
            for (final clip in track.clips) clip.copyWith(region: clip.region.normalized(target)),
          ]),
      ],
    );
  }

  /// Changes the frame rate ([CompositionErrorKind.invalidValue] for one
  /// outside [Composition.supportedFramerates]).
  Composition setFramerate(Framerate framerate) =>
      framerate == this.framerate ? this : _guard(() => copyWith(framerate: framerate));

  /// Renames the composition ([CompositionErrorKind.invalidValue] for a name
  /// with the NUL character).
  Composition rename(String name) => name == this.name ? this : _guard(() => copyWith(name: name));

  /// Sets or (with `null`) removes the beat grid.
  Composition setTempo(Tempo? tempo) => tempo == null ? copyWith(removeTempo: true) : copyWith(tempo: tempo);

  // ---------------------------------------------------------------- helpers

  AudioTrack _audio() =>
      audio ??
      (throw const CompositionException(CompositionErrorKind.invalidValue, 'The composition has no soundtrack.'));

  AudioSegment _audioSegment(AudioTrack audio, String segmentId) =>
      audio.segmentById(segmentId) ??
      (throw CompositionException(CompositionErrorKind.audioSegmentNotFound, 'Audio segment "$segmentId" not found.'));

  VisualTrack _track(String trackId) =>
      trackById(trackId) ??
      (throw CompositionException(CompositionErrorKind.trackNotFound, 'Track "$trackId" not found.'));

  VisualTrack _unlockedTrack(String trackId) {
    final track = _track(trackId);
    if (track.locked) throw CompositionException(CompositionErrorKind.trackLocked, 'Track "$trackId" is locked.');
    return track;
  }

  PlacedClip _editableClip(String clipId) {
    final placed = findClip(clipId);
    if (placed == null) throw CompositionException(CompositionErrorKind.clipNotFound, 'Clip "$clipId" not found.');
    if (placed.track.locked) {
      throw CompositionException(CompositionErrorKind.trackLocked, 'Track "${placed.track.id}" is locked.');
    }
    return placed;
  }

  void _ensureClipIdFree(String clipId) {
    if (findClip(clipId) != null) {
      throw CompositionException(CompositionErrorKind.duplicateId, 'Clip id "$clipId" is already used.');
    }
  }

  (VisualTrack, Transition)? _findTransition(String transitionId) {
    for (final track in tracks) {
      final transition = track.transitionById(transitionId);
      if (transition != null) return (track, transition);
    }
    return null;
  }

  (VisualTrack, Transition) _transition(String transitionId) =>
      _findTransition(transitionId) ??
      (throw CompositionException(CompositionErrorKind.transitionNotFound, 'Transition "$transitionId" not found.'));

  Marker _marker(String markerId) =>
      markerById(markerId) ??
      (throw CompositionException(CompositionErrorKind.markerNotFound, 'Marker "$markerId" not found.'));

  MacroDef _macro(String macroId) =>
      macroById(macroId) ??
      (throw CompositionException(CompositionErrorKind.macroNotFound, 'Macro "$macroId" not found.'));

  /// Throws [CompositionErrorKind.overlap] when two of the sorted [clips]
  /// overlap.
  void _ensureNoOverlap(List<Clip> clips, String trackId) {
    for (var i = 1; i < clips.length; i++) {
      if (clips[i - 1].end > clips[i].start) {
        throw CompositionException(
          CompositionErrorKind.overlap,
          'Clips "${clips[i - 1].id}" and "${clips[i].id}" would overlap on track "$trackId".',
        );
      }
    }
  }

  /// [clip] with the given look replaced; `null` keeps a property. Fades are
  /// clamped to the clip duration, the opacity to `[0, 1]`.
  Clip _withProps(
    Clip clip, {
    BlendMode? blend,
    double? opacity,
    Duration? fadeIn,
    Duration? fadeOut,
    Region? region,
    bool? isMask,
    bool? reverse,
    bool? pingPong,
    ClipLabel? label,
  }) {
    Duration? fade(Duration? value) => value == null ? null : _clampDuration(value, Duration.zero, clip.duration);
    if (pingPong == true && !clip.isLooping) {
      throw CompositionException(CompositionErrorKind.invalidValue, 'Clip "${clip.id}" does not loop.');
    }
    return _guard(() => clip.copyWith(
          blend: blend,
          opacity: opacity == null ? null : _unit(opacity, 'opacity'),
          fadeIn: fade(fadeIn),
          fadeOut: fade(fadeOut),
          region: region,
          isMask: isMask,
          reverse: reverse,
          pingPong: pingPong,
          label: label,
        ));
  }

  Composition _replaceTrack(VisualTrack updated) =>
      copyWith(tracks: [for (final track in tracks) track.id == updated.id ? updated : track]);

  /// Replaces the clips of [track], re-fits its transitions and re-anchors
  /// the audio-bound generator clips.
  Composition _replaceClips(VisualTrack track, List<Clip> clips, {List<Transition>? transitions}) {
    final sorted = [...clips]..sort((a, b) => a.start.compareTo(b.start));
    final fitted = fitTransitions(sorted, transitions ?? track.transitions);
    return _guard(() => reanchorGeneratorClips(_replaceTrack(track.copyWith(clips: sorted, transitions: fitted.kept))));
  }
}

/// Free span on a track, [upper] `null` meaning unbounded.
typedef _Bounds = ({Duration lower, Duration? upper});

/// Converts model validation failures into [CompositionException]s.
T _guard<T>(T Function() build) {
  try {
    return build();
  } on ArgumentError catch (error) {
    throw CompositionException(CompositionErrorKind.invalidValue, '${error.message}');
  }
}

double _unit(double value, String name) {
  if (!value.isFinite) throw CompositionException(CompositionErrorKind.invalidValue, '$name $value is not finite.');
  return value.clamp(0.0, 1.0).toDouble();
}

Duration _us(int microseconds) => Duration(microseconds: microseconds);

Duration _clampDuration(Duration value, Duration lower, Duration upper) =>
    value < lower ? lower : (value > upper ? upper : value);

Duration _scaled(Duration value, double factor) {
  final scaled = (value.inMicroseconds * factor).round();
  return _us(scaled < 1 ? 1 : scaled);
}

/// The largest source range whose derived duration at [speed] is at most
/// [duration].
int _rangeWithin(Duration duration, double speed) => (duration.inMicroseconds * speed).floor();

/// The smallest source range giving at least [Clip.minDuration] at [speed].
int _minRange(double speed) => (Clip.minDuration.inMicroseconds * speed).ceil();

/// The space a clip can grow into: from the previous clip end (or the
/// timeline start) to the next clip start.
_Bounds _bounds(VisualTrack track, Clip clip) {
  var lower = Duration.zero;
  Duration? upper;
  for (final other in track.clips) {
    if (other.id == clip.id) continue;
    if (other.end <= clip.start && other.end > lower) lower = other.end;
    if (other.start >= clip.end && (upper == null || other.start < upper)) upper = other.start;
  }
  return (lower: lower, upper: upper);
}

/// Start of a span of [duration] placed in the free gap between [clips]
/// that fits it and is nearest to [desired] (earlier gap on a tie).
Duration _placeInGap(List<Clip> clips, Duration desired, Duration duration) {
  final sorted = [...clips]..sort((a, b) => a.start.compareTo(b.start));
  Duration? best;
  var bestDistance = 0;
  var gapStart = Duration.zero;
  void consider(Duration from, Duration? to) {
    if (to != null && to - from < duration) return;
    var start = desired < from ? from : desired;
    if (to != null && start + duration > to) start = to - duration;
    final distance = (start - desired).inMicroseconds.abs();
    if (best == null || distance < bestDistance) {
      best = start;
      bestDistance = distance;
    }
  }

  for (final clip in sorted) {
    consider(gapStart, clip.start);
    if (clip.end > gapStart) gapStart = clip.end;
  }
  consider(gapStart, null);
  return best!;
}

/// Start of a span of [length] (`null` = unbounded) placed in the free gap
/// between the audio [segments] that fits it and is nearest to [desired];
/// `null` when nothing fits. Open-ended segments are resolved against
/// [sourceLength] (unbounded without it).
Duration? _placeAudioInGap(List<AudioSegment> segments, Duration desired, Duration? length, Duration? sourceLength) {
  final sorted = [...segments]..sort((a, b) => a.start.compareTo(b.start));
  Duration? best;
  var bestDistance = 0;
  var gapStart = Duration.zero;
  var open = false;
  void consider(Duration from, Duration? to) {
    if (length == null && to != null) return;
    if (to != null && to - from < length!) return;
    var start = desired < from ? from : desired;
    if (to != null && start + length! > to) start = to - length;
    final distance = (start - desired).inMicroseconds.abs();
    if (best == null || distance < bestDistance) {
      best = start;
      bestDistance = distance;
    }
  }

  for (final segment in sorted) {
    consider(gapStart, segment.start);
    final end = sourceLength == null ? segment.end : segment.endFor(sourceLength);
    if (end == null) {
      open = true;
      break;
    }
    if (end > gapStart) gapStart = end;
  }
  if (!open) consider(gapStart, null);
  return best;
}

/// Plain edge drag of a clip that plays once: moves the trim.
Clip _trim(Clip clip, ClipEdge edge, Duration to, _Bounds bounds, Duration sourceDuration) {
  final speed = clip.speed;
  final minRange = _minRange(speed);
  switch (edge) {
    case ClipEdge.end:
      final upper = bounds.upper;
      var range = ((to - clip.start).inMicroseconds * speed).round();
      if (upper != null) range = _min(range, _rangeWithin(upper - clip.start, speed));
      range = _max(range, minRange);
      var sourceOut = clip.sourceIn.inMicroseconds + range;
      sourceOut = _min(sourceOut, sourceDuration.inMicroseconds);
      if (sourceOut <= clip.sourceIn.inMicroseconds) return clip;
      final trimmed = _guard(() => clip.copyWith(sourceOut: _us(sourceOut)));
      return upper != null && trimmed.end > upper ? clip : trimmed;
    case ClipEdge.start:
      final end = clip.end;
      var range = ((end - to).inMicroseconds * speed).round();
      range = _min(range, _rangeWithin(end - bounds.lower, speed));
      range = _max(range, minRange);
      final sourceIn = _max(clip.sourceOut.inMicroseconds - range, 0);
      if (sourceIn >= clip.sourceOut.inMicroseconds) return clip;
      final trimmed = _guard(() => clip.copyWith(sourceIn: _us(sourceIn)));
      final start = end - trimmed.duration;
      return start < bounds.lower ? clip : trimmed.copyWith(start: start);
  }
}

/// Edge drag of a generator or effect clip (speed 1, no loop): the end edge
/// sets the ref's length to the new `sourceOut` (at most [maxBakeLength]),
/// the start edge trims `sourceIn`.
Clip _dragGeneratorEdge(Clip clip, ClipEdge edge, Duration to, _Bounds bounds) {
  final source = clip.source as ParametricRef;
  final minRange = Clip.minDuration.inMicroseconds;
  switch (edge) {
    case ClipEdge.end:
      final upper = bounds.upper;
      var range = (to - clip.start).inMicroseconds;
      if (upper != null) range = _min(range, (upper - clip.start).inMicroseconds);
      range = _max(range, minRange);
      var sourceOut = clip.sourceIn.inMicroseconds + range;
      sourceOut = _min(sourceOut, maxBakeLength.inMicroseconds);
      if (sourceOut <= clip.sourceIn.inMicroseconds) return clip;
      final length = _us(sourceOut);
      final trimmed = _guard(() => clip.copyWith(sourceOut: length, source: source.copyWith(length: length)));
      return upper != null && trimmed.end > upper ? clip : trimmed;
    case ClipEdge.start:
      final end = clip.end;
      var range = (end - to).inMicroseconds;
      range = _min(range, (end - bounds.lower).inMicroseconds);
      range = _max(range, minRange);
      final sourceIn = _max(clip.sourceOut.inMicroseconds - range, 0);
      if (sourceIn >= clip.sourceOut.inMicroseconds) return clip;
      final trimmed = _guard(() => clip.copyWith(sourceIn: _us(sourceIn)));
      final start = end - trimmed.duration;
      return start < bounds.lower ? clip : trimmed.copyWith(start: start);
  }
}

/// Plain edge drag of a looping clip.
Clip _dragLoopEdge(Clip clip, ClipEdge edge, Duration to, _Bounds bounds) {
  switch (edge) {
    case ClipEdge.end:
      var loop = _maxDuration(to - clip.start, Clip.minDuration);
      final upper = bounds.upper;
      if (upper != null && clip.start + loop > upper) loop = upper - clip.start;
      return clip.copyWith(loopDuration: loop);
    case ClipEdge.start:
      final end = clip.end;
      var start = _clampDuration(to, bounds.lower, end - Clip.minDuration);
      if (start < bounds.lower) start = bounds.lower;
      final shift = ((start - clip.start).inMicroseconds * clip.speed).round();
      final maxIn = clip.sourceOut.inMicroseconds - _max(1, _minRange(clip.speed));
      final sourceIn = (clip.sourceIn.inMicroseconds + shift).clamp(0, _max(0, maxIn));
      return _guard(() => clip.copyWith(start: start, sourceIn: _us(sourceIn), loopDuration: end - start));
  }
}

/// Shift + edge drag: changes the speed, keeps the trim.
Clip _stretch(Clip clip, ClipEdge edge, Duration to, _Bounds bounds) {
  final end = clip.end;
  final upper = bounds.upper;
  var length = edge == ClipEdge.end ? to - clip.start : end - to;
  final maxLength = edge == ClipEdge.end ? (upper == null ? null : upper - clip.start) : end - bounds.lower;
  if (maxLength != null && length > maxLength) length = maxLength;
  length = _maxDuration(length, Clip.minDuration);

  final loop = clip.loopDuration;
  final Clip stretched;
  if (loop == null) {
    final range = clip.sourceRange.inMicroseconds;
    var speed = (range / length.inMicroseconds).clamp(Clip.minSpeed, Clip.maxSpeed).toDouble();
    if (maxLength != null && (range / speed).round() > maxLength.inMicroseconds) {
      speed = (range / (maxLength.inMicroseconds - 0.5)).clamp(Clip.minSpeed, Clip.maxSpeed).toDouble();
    }
    stretched = _guard(() => clip.copyWith(speed: speed));
  } else {
    final speed =
        (clip.speed * loop.inMicroseconds / length.inMicroseconds).clamp(Clip.minSpeed, Clip.maxSpeed).toDouble();
    var newLoop = _scaled(loop, clip.speed / speed);
    if (maxLength != null && newLoop > maxLength) newLoop = maxLength;
    stretched = _guard(() => clip.copyWith(speed: speed, loopDuration: newLoop));
  }
  if (edge == ClipEdge.end) {
    return upper != null && stretched.end > upper ? clip : stretched;
  }
  final start = end - stretched.duration;
  return start < bounds.lower ? clip : stretched.copyWith(start: start);
}

/// Splits a clip that plays once.
(Clip, Clip) _splitOnce(Clip clip, Duration at, String newClipId) {
  final rangeTotal = clip.sourceRange.inMicroseconds;
  final leftRange = ((at - clip.start).inMicroseconds * clip.speed).round().clamp(1, rangeTotal - 1);
  final left = _guard(() => clip.copyWith(sourceOut: clip.sourceIn + _us(leftRange), fadeOut: Duration.zero));
  var right = _guard(() => clip.copyWith(
        id: newClipId,
        start: left.end,
        sourceIn: left.sourceOut,
        fadeIn: Duration.zero,
      ));
  right = _fitEnd(right, clip.end);
  return (_withFadesWithin(left), _withFadesWithin(right));
}

/// Splits a looping clip.
(Clip, Clip) _splitLoop(Clip clip, Duration at, String newClipId) {
  final left = clip.copyWith(loopDuration: at - clip.start, fadeOut: Duration.zero);
  final remaining = clip.end - at;
  final range = clip.sourceRange.inMicroseconds;
  final phase = ((at - clip.start).inMicroseconds * clip.speed).floor() % range;
  Clip right;
  final remainingRange = (remaining.inMicroseconds * clip.speed).round();
  if (phase != 0 && remainingRange <= range - phase) {
    right = _guard(() => clip.copyWith(
          id: newClipId,
          start: at,
          sourceIn: clip.sourceIn + _us(phase),
          sourceOut: clip.sourceIn + _us(phase + _max(1, remainingRange)),
          removeLoop: true,
          fadeIn: Duration.zero,
        ));
    right = _fitEnd(right, clip.end);
  } else {
    right = clip.copyWith(id: newClipId, start: at, loopDuration: remaining, fadeIn: Duration.zero);
  }
  return (_withFadesWithin(left), _withFadesWithin(right));
}

/// Shortens the trim of a clip that plays once until it ends by [end].
Clip _fitEnd(Clip clip, Duration end) {
  var fitted = clip;
  while (fitted.end > end && fitted.sourceRange > const Duration(microseconds: 1)) {
    fitted = fitted.copyWith(sourceOut: fitted.sourceOut - const Duration(microseconds: 1));
  }
  return fitted;
}

Clip _withFadesWithin(Clip clip) {
  final length = clip.duration;
  if (clip.fadeIn <= length && clip.fadeOut <= length) return clip;
  return clip.copyWith(
    fadeIn: clip.fadeIn > length ? length : clip.fadeIn,
    fadeOut: clip.fadeOut > length ? length : clip.fadeOut,
  );
}

Duration _maxDuration(Duration a, Duration b) => a > b ? a : b;

int _min(int a, int b) => a < b ? a : b;

int _max(int a, int b) => a > b ? a : b;

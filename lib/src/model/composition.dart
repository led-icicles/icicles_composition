import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_generators/icicles_generators.dart';

import 'audio_track.dart';
import 'clip.dart';
import 'cue_track.dart';
import 'loop_range.dart';
import 'macro_def.dart';
import 'marker.dart';
import 'output_spec.dart';
import 'source_ref.dart';
import 'stage_layout.dart';
import 'visual_track.dart';

/// A clip together with the track holding it.
typedef PlacedClip = ({VisualTrack track, Clip clip});

/// A timeline of clips on tracks over an optional music track, rendered
/// into one animation for [target].
class Composition extends Equatable {
  /// Frame rates a composition renders at.
  static const supportedFramerates = [Framerate.fps30, Framerate.fps45];

  /// Name of the exported animation; it cannot contain the NUL character.
  final String name;

  final OutputSpec target;

  /// One of [supportedFramerates].
  final Framerate framerate;

  /// Ordered bottom to top.
  final List<VisualTrack> tracks;

  /// The music track, `null` without a soundtrack.
  final AudioTrack? audio;
  final Tempo? tempo;

  /// Sorted by time.
  final List<Marker> markers;

  /// The in/out points, `null` when none are set.
  final LoopRange? loopRange;

  /// The composition's macros (global bindings parameters read through a
  /// `MacroBinding`), in definition order.
  final List<MacroDef> macros;

  /// The cue tracks (timing tracks of marks that cue triggers fire on), in
  /// display order.
  final List<CueTrack> cueTracks;

  /// How the installation is arranged in the preview (the application's
  /// panel layout), `null` when the project does not record one. Rendering
  /// ignores it.
  final StageLayout? stageLayout;

  /// Throws an [ArgumentError] for an unsupported [framerate], a name with
  /// the NUL character or repeated track, clip, marker, macro or cue track
  /// ids (clip ids are unique across tracks).
  Composition({
    required this.name,
    required this.target,
    this.framerate = Framerate.fps30,
    List<VisualTrack> tracks = const [],
    this.audio,
    this.tempo,
    List<Marker> markers = const [],
    this.loopRange,
    List<MacroDef> macros = const [],
    List<CueTrack> cueTracks = const [],
    this.stageLayout,
  })  : tracks = List.unmodifiable(tracks),
        markers = List.unmodifiable(markers.sorted((a, b) => a.at.compareTo(b.at))),
        macros = List.unmodifiable(macros),
        cueTracks = List.unmodifiable(cueTracks) {
    if (name.contains('\u0000')) {
      throw ArgumentError.value(name, 'name', 'Must not contain the NUL character.');
    }
    if (!supportedFramerates.contains(framerate)) {
      throw ArgumentError.value(framerate, 'framerate', 'Supported: $supportedFramerates.');
    }
    final trackIds = <String>{};
    final clipIds = <String>{};
    for (final track in this.tracks) {
      if (!trackIds.add(track.id)) throw ArgumentError('Duplicate track id "${track.id}".');
      for (final clip in track.clips) {
        if (!clipIds.add(clip.id)) throw ArgumentError('Duplicate clip id "${clip.id}".');
      }
    }
    final markerIds = <String>{};
    for (final marker in this.markers) {
      if (!markerIds.add(marker.id)) throw ArgumentError('Duplicate marker id "${marker.id}".');
    }
    final macroIds = <String>{};
    for (final macro in this.macros) {
      if (!macroIds.add(macro.id)) throw ArgumentError('Duplicate macro id "${macro.id}".');
    }
    final cueTrackIds = <String>{};
    for (final track in this.cueTracks) {
      if (!cueTrackIds.add(track.id)) throw ArgumentError('Duplicate cue track id "${track.id}".');
    }
  }

  /// End of the last clip on any track; the length of the export.
  Duration get duration => tracks.isEmpty ? Duration.zero : tracks.map((track) => track.end).max;

  /// Every clip on every track, bottom track first.
  Iterable<PlacedClip> get placedClips sync* {
    for (final track in tracks) {
      for (final clip in track.clips) {
        yield (track: track, clip: clip);
      }
    }
  }

  /// Every distinct source used by the clips.
  Set<SourceRef> get sources => {for (final placed in placedClips) placed.clip.source};

  VisualTrack? trackById(String trackId) => tracks.firstWhereOrNull((track) => track.id == trackId);

  /// The clip with [clipId] and its track.
  PlacedClip? findClip(String clipId) {
    for (final track in tracks) {
      final clip = track.clipById(clipId);
      if (clip != null) return (track: track, clip: clip);
    }
    return null;
  }

  Marker? markerById(String markerId) => markers.firstWhereOrNull((marker) => marker.id == markerId);

  MacroDef? macroById(String macroId) => macros.firstWhereOrNull((macro) => macro.id == macroId);

  CueTrack? cueTrackById(String cueTrackId) => cueTracks.firstWhereOrNull((track) => track.id == cueTrackId);

  /// The cue track [ref] fires on: its `cueTrackId` when that track exists,
  /// else the first cue track; `null` without cue tracks.
  CueTrack? cueTrackFor(ParametricRef ref) =>
      (ref.cueTrackId == null ? null : cueTrackById(ref.cueTrackId!)) ?? cueTracks.firstOrNull;

  /// Every macro's binding by id: what a bake takes as `BakeRequest.macros`.
  Map<String, ParamBinding> get macroBindings => {for (final macro in macros) macro.id: macro.binding};

  /// The macros (by id) that [bindings] read, directly or through a stack
  /// (see [macroIdsOf]); a bake of those bindings needs only these. Unknown
  /// ids are left out (the parameter then falls back to its default).
  Map<String, ParamBinding> macrosUsedBy(Map<String, ParamBinding> bindings) {
    final ids = {for (final binding in bindings.values) ...macroIdsOf(binding)};
    return {
      for (final macro in macros)
        if (ids.contains(macro.id)) macro.id: macro.binding,
    };
  }

  /// Whether any track is solo, so that only the solo tracks are drawn.
  bool get hasSolo => tracks.any((track) => track.solo);

  /// Whether [track] is drawn as far as mute/solo go: unmuted and, while
  /// [hasSolo], solo.
  bool isTrackAudible(VisualTrack track) => !track.muted && (!hasSolo || track.solo);

  /// A copy with the given fields replaced; [removeAudio], [removeTempo] and
  /// [removeLoopRange] and [removeStageLayout] set them to `null`.
  Composition copyWith({
    String? name,
    OutputSpec? target,
    Framerate? framerate,
    List<VisualTrack>? tracks,
    AudioTrack? audio,
    bool removeAudio = false,
    Tempo? tempo,
    bool removeTempo = false,
    List<Marker>? markers,
    LoopRange? loopRange,
    bool removeLoopRange = false,
    List<MacroDef>? macros,
    List<CueTrack>? cueTracks,
    StageLayout? stageLayout,
    bool removeStageLayout = false,
  }) =>
      Composition(
        name: name ?? this.name,
        target: target ?? this.target,
        framerate: framerate ?? this.framerate,
        tracks: tracks ?? this.tracks,
        audio: removeAudio ? null : (audio ?? this.audio),
        tempo: removeTempo ? null : (tempo ?? this.tempo),
        markers: markers ?? this.markers,
        loopRange: removeLoopRange ? null : (loopRange ?? this.loopRange),
        macros: macros ?? this.macros,
        cueTracks: cueTracks ?? this.cueTracks,
        stageLayout: removeStageLayout ? null : (stageLayout ?? this.stageLayout),
      );

  @override
  List<Object?> get props =>
      [name, target, framerate, tracks, audio, tempo, markers, loopRange, macros, cueTracks, stageLayout];
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_generators/icicles_generators.dart';

import '../model/audio_track.dart';
import '../model/clip.dart';
import '../model/clip_label.dart';
import '../model/composition.dart';
import '../model/cue_track.dart';
import '../model/loop_range.dart';
import '../model/macro_def.dart';
import '../model/marker.dart';
import '../model/output_spec.dart';
import '../model/pixel_mask.dart';
import '../model/region.dart';
import '../model/source_ref.dart';
import '../model/transition.dart';
import '../model/transition_fitting.dart';
import '../model/visual_track.dart';
import 'drawing_pixels_codec.dart';

/// Why a `.icproj` document could not be read at all.
enum IcprojErrorKind {
  /// The text is not JSON, or its root is not an object.
  invalidJson,

  /// The `format` field is not `"icproj"`.
  notIcproj,

  /// The `version` is not one this codec reads (e.g. a newer file).
  unsupportedVersion,

  /// A part the project cannot do without (the version or the target) is
  /// missing or invalid.
  invalidProject,
}

/// A `.icproj` document that could not be read.
class IcprojException implements Exception {
  final IcprojErrorKind kind;

  /// Technical description, not meant for end users.
  final String message;

  const IcprojException(this.kind, this.message);

  @override
  String toString() => 'IcprojException(${kind.name}): $message';
}

/// What [IcprojCodec.decode] repaired while reading a document.
enum IcprojProblemKind {
  droppedTrack,
  droppedClip,
  droppedTransition,
  droppedMarker,

  /// A macro definition was unreadable and was dropped; parameters reading
  /// it fall back to their defaults.
  droppedMacro,

  /// A cue track was unreadable and was dropped; clips naming it follow the
  /// first remaining cue track.
  droppedCueTrack,

  /// A cue of a cue track was unreadable (or repeated an id) and was
  /// dropped.
  droppedCue,
  droppedAudio,
  droppedTempo,

  /// A drawing frame was unreadable and was dropped (a drawing without a
  /// readable frame drops its clip).
  droppedFrame,

  /// A generator parameter binding was unreadable and was dropped; the
  /// parameter uses its default.
  droppedBinding,

  /// A number was out of range and was clamped.
  clampedValue,

  /// A value was missing or unknown and its default was used.
  defaultedValue,
}

/// A repair made while decoding; the project opened anyway.
class IcprojProblem extends Equatable {
  final IcprojProblemKind kind;

  /// Location in the document, e.g. `tracks[0].clips[2].speed`.
  final String path;

  /// Technical description, not meant for end users.
  final String message;

  const IcprojProblem(this.kind, this.path, this.message);

  @override
  List<Object?> get props => [kind, path, message];

  @override
  String toString() => 'IcprojProblem(${kind.name}, $path: $message)';
}

/// A decoded project with the repairs made on the way.
class IcprojDecodeResult {
  final Composition composition;
  final List<IcprojProblem> problems;

  IcprojDecodeResult(this.composition, List<IcprojProblem> problems) : problems = List.unmodifiable(problems);
}

/// The `.icproj` project format: JSON `{"format": "icproj", "version": 2, …}`.
///
/// - Times are integer microseconds in fields ending with `Us`.
/// - Paths are stored as given (relative to the project file by
///   convention); resolving them is the application's job.
/// - A clip `source` is `{"type": "file", "path", "contentHash"}` or
///   `{"type": "generator", "id", "version", "seed", "lengthUs",
///   "audioOriginUs"?, "params": {paramId: binding}, "reactivity"?: {…}}`
///   (bindings in the [ParamBindingJson] form; `reactivity` in the
///   `AudioReactivityJson` form, omitted while it is `AudioReactivity.none`
///   — an unreadable one falls back to none with `defaultedValue`). Version 1 had file sources only, written
///   without `type`; a composition without generator clips is still written
///   as version 1, exactly as before, so existing files do not change.
/// - A clip `region` is `{"icicles": bool, "columns": [first, last]?,
///   "panels": "all" | "none" | [1, 3, …]}` (0-based inclusive columns,
///   1-based panels). Version 1 wrote the strings `all`, `icicles` and
///   `radioPanels`; a composition whose regions are all classic (and has no
///   generator clips) is still written as version 1 with those strings.
///   A per-pixel mask is `"pixels": {"x", "y", "panels", "panelPixels",
///   "bits": base64}` inside the region (icicle pixels first, then panel
///   pixels, little-endian bits), omitted when absent.
/// - A mask clip ([Clip.isMask]) carries `"mask": true` (omitted when
///   false); it makes the document version 2.
/// - The soundtrack is `"audio": {"path", "gain", "offsetUs"}` in version 1
///   (one open-ended segment of the whole file at that timeline offset) and,
///   once split, moved or trimmed, `{"path", "gain", "segments": [{"id",
///   "startUs", "sourceInUs", "sourceOutUs"?}]}` in version 2 (`sourceOutUs`
///   omitted for a segment playing to the file end). A plain soundtrack is
///   still written in the version 1 shape.
/// - Version 2 also adds, each omitted at its default: a clip `"reverse"`,
///   `"pingPong"` (booleans) and `"label"` (a [ClipLabel] name), a track
///   `"solo"`, a marker `"color"` (a [ClipLabel] name) and the composition
///   `"loopRange": {"startUs", "endUs"}`, and the composition `"macros"`:
///   `[{"id", "name", "kind": "number" | "color", "min", "max", "default"
///   (number) | "defaultColor" (color), "binding"}]` (the binding in the
///   [ParamBindingJson] form), and the composition `"cueTracks"`: `[{"id",
///   "name", "color"?, "cues": {"ids": [], "us": [], "s": []}}]` (cue ids,
///   timeline microseconds and strengths, column-wise) with a generator or
///   effect source naming its track in `"cueTrack"`. Any of them being set
///   makes the document version 2; a document without them keeps its
///   version 1 bytes.
/// - Decoding is strict about the format and version but salvages the rest:
///   an invalid track, clip, transition or marker is dropped, numbers are
///   clamped to their ranges and unknown values replaced by defaults, each
///   reported as an [IcprojProblem]. Unknown fields are ignored.
/// - Encoding is stable (sorted keys, two-space indent, trailing newline) so
///   files diff well.
abstract final class IcprojCodec {
  /// Value of the `format` field.
  static const format = 'icproj';

  /// The newest `version` this codec writes.
  static const currentVersion = 2;

  /// The `version`s this codec reads.
  static const supportedVersions = [1, 2];

  /// File extension, without the dot.
  static const fileExtension = 'icproj';

  /// The `version` [composition] is written as: 1 with file clips only (no
  /// generator, effect, image, drawing or nested-composition clips), without
  /// mask, reversed, ping-pong or labelled clips, solo tracks,
  /// colored markers, macros or a loop range, and with classic regions only
  /// ([Region.isClassic]); [currentVersion] otherwise.
  static int versionFor(Composition composition) {
    if (composition.loopRange != null) return currentVersion;
    if (composition.audio case final audio? when !audio.isSingleWhole) return currentVersion;
    if (composition.macros.isNotEmpty) return currentVersion;
    if (composition.cueTracks.isNotEmpty) return currentVersion;
    if (composition.tracks.any((track) => track.solo)) return currentVersion;
    if (composition.markers.any((marker) => marker.color != ClipLabel.none)) return currentVersion;
    final needsV2 = composition.placedClips.any((placed) {
      final clip = placed.clip;
      return clip.source is! AnimationFileRef ||
          clip.isMask ||
          clip.reverse ||
          clip.pingPong ||
          clip.label != ClipLabel.none ||
          !clip.region.isClassic;
    });
    return needsV2 ? currentVersion : 1;
  }

  /// [composition] as a `.icproj` document.
  static String encode(Composition composition) =>
      '${const JsonEncoder.withIndent('  ').convert(_sorted(toJson(composition)))}\n';

  /// [composition] as a JSON object (keys in insertion order).
  static Map<String, Object?> toJson(Composition composition) => {
        'format': format,
        'version': versionFor(composition),
        'name': composition.name,
        'framerate': composition.framerate.framesPerSecond,
        'target': _targetToJson(composition.target),
        'tracks': [
          for (final track in composition.tracks) _trackToJson(track, legacy: versionFor(composition) == 1),
        ],
        if (composition.audio case final audio?) 'audio': _audioToJson(audio),
        if (composition.tempo case final tempo?)
          'tempo': {'bpm': tempo.bpm, 'firstBeatOffsetUs': tempo.firstBeatOffset.inMicroseconds},
        'markers': [
          for (final marker in composition.markers)
            {
              'id': marker.id,
              'atUs': marker.at.inMicroseconds,
              'label': marker.label,
              if (marker.color != ClipLabel.none) 'color': marker.color.name,
            },
        ],
        if (composition.loopRange case final range?)
          'loopRange': {'startUs': range.start.inMicroseconds, 'endUs': range.end.inMicroseconds},
        if (composition.macros.isNotEmpty)
          'macros': [
            for (final macro in composition.macros)
              {
                'id': macro.id,
                'name': macro.name,
                'kind': macro.kind.name,
                if (macro.isNumber) ...{
                  'min': macro.min,
                  'max': macro.max,
                  'default': macro.defaultValue,
                } else
                  'defaultColor': colorToHex(macro.defaultValue as Color),
                'binding': ParamBindingJson.toJson(macro.binding),
              },
          ],
        if (composition.cueTracks.isNotEmpty)
          'cueTracks': [
            for (final track in composition.cueTracks)
              {
                'id': track.id,
                'name': track.name,
                if (track.color != ClipLabel.none) 'color': track.color.name,
                'cues': {
                  'ids': [for (final cue in track.cues) cue.id],
                  'us': [for (final cue in track.cues) cue.at.inMicroseconds],
                  's': [for (final cue in track.cues) cue.strength],
                },
              },
          ],
      };

  /// The version 1 shape `{path, gain, offsetUs}` for a plain soundtrack
  /// ([AudioTrack.isSingleWhole]), else `{path, gain, segments: [{id,
  /// startUs, sourceInUs, sourceOutUs?}]}`.
  static Map<String, Object?> _audioToJson(AudioTrack audio) => {
        'path': audio.path,
        'gain': audio.gain,
        if (audio.isSingleWhole)
          'offsetUs': audio.offset.inMicroseconds
        else
          'segments': [
            for (final segment in audio.segments)
              {
                'id': segment.id,
                'startUs': segment.start.inMicroseconds,
                'sourceInUs': segment.sourceIn.inMicroseconds,
                if (segment.sourceOut case final out?) 'sourceOutUs': out.inMicroseconds,
              },
          ],
      };

  /// A clip source as its `.icproj` JSON object (the version 2 shape, with
  /// `type`): what the application stores when it keeps a source outside a
  /// document (e.g. the media bin's unplaced sources).
  static Map<String, Object?> sourceToJson(SourceRef source) => _sourceToJson(source, legacy: false);

  /// Reads a source written by [sourceToJson] (salvage problems are
  /// repaired silently); throws an [IcprojException] (`invalidProject`) for
  /// an unreadable one.
  static SourceRef sourceFromJson(Object? json) {
    final decoder = _Decoder();
    try {
      return decoder._source(_Fields.of(json, r'$', decoder.problems));
    } on _Invalid catch (error) {
      throw IcprojException(IcprojErrorKind.invalidProject, error.message);
    } on ArgumentError catch (error) {
      throw IcprojException(IcprojErrorKind.invalidProject, '${error.message}');
    }
  }

  /// Reads a `.icproj` document; throws an [IcprojException] when it cannot
  /// be read at all.
  static IcprojDecodeResult decode(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (error) {
      throw IcprojException(IcprojErrorKind.invalidJson, 'Not JSON: ${error.message}');
    }
    return fromJson(json);
  }

  /// Reads a decoded JSON value; see [decode].
  static IcprojDecodeResult fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const IcprojException(IcprojErrorKind.invalidJson, 'The document root is not an object.');
    }
    if (json['format'] != format) {
      throw IcprojException(IcprojErrorKind.notIcproj, 'The format is "${json['format']}", expected "$format".');
    }
    final version = json['version'];
    if (version is! int) {
      throw IcprojException(IcprojErrorKind.invalidProject, 'The version "$version" is not an integer.');
    }
    if (!supportedVersions.contains(version)) {
      throw IcprojException(
        IcprojErrorKind.unsupportedVersion,
        'Version $version is not supported, this codec reads versions ${supportedVersions.join(', ')}.',
      );
    }
    return _Decoder().decode(json);
  }
}

Map<String, Object?> _targetToJson(OutputSpec target) => {
      'xCount': target.xCount,
      'yCount': target.yCount,
      'radioPanelsCount': target.radioPanelsCount,
      'radioPanelPixelCount': target.radioPanelPixelCount,
      'animationVersion': target.version.value,
    };

Map<String, Object?> _trackToJson(VisualTrack track, {required bool legacy}) => {
      'id': track.id,
      'name': track.name,
      'muted': track.muted,
      if (track.solo) 'solo': true,
      'locked': track.locked,
      'opacity': track.opacity,
      'clips': [for (final clip in track.clips) _clipToJson(clip, legacy: legacy)],
      'transitions': [
        for (final transition in track.transitions)
          {
            'id': transition.id,
            'fromClipId': transition.fromClipId,
            'toClipId': transition.toClipId,
            'durationUs': transition.duration.inMicroseconds,
            'alignment': transition.alignment.name,
          },
      ],
    };

/// The clip source; a file keeps the version 1 shape (no `type`) when
/// [legacy] (the document is written as version 1).
Map<String, Object?> _sourceToJson(SourceRef source, {required bool legacy}) => switch (source) {
      AnimationFileRef(:final path, :final contentHash) => {
          if (!legacy) 'type': 'file',
          'path': path,
          'contentHash': contentHash,
        },
      GeneratorRef() => _parametricToJson('generator', source),
      EffectRef() => _parametricToJson('effect', source),
      ImageRef(:final paths, :final contentHash, :final fit, :final panels, :final frameDuration) => {
          'type': 'image',
          if (paths.length == 1) 'path': paths.single else 'paths': paths,
          'contentHash': contentHash,
          'fit': fit.name,
          'panels': panels.name,
          if (frameDuration != null) 'frameDurationUs': frameDuration.inMicroseconds,
        },
      DrawingRef() => {
          'type': 'drawing',
          'id': source.id,
          'name': source.name,
          'x': source.xCount,
          'y': source.yCount,
          'panels': source.radioPanelsCount,
          'panelPixels': source.radioPanelPixelCount,
          'frames': [
            for (final frame in source.frames)
              {'durationUs': frame.duration.inMicroseconds, 'pixels': DrawingPixelsCodec.encode(frame.pixels)},
          ],
        },
      CompositionRef(:final path, :final contentHash) => {
          'type': 'composition',
          'path': path,
          'contentHash': contentHash,
        },
    };

Map<String, Object?> _parametricToJson(String type, ParametricRef source) => {
      'type': type,
      'id': source.programId,
      'version': source.programVersion,
      'seed': source.seed,
      'lengthUs': source.length.inMicroseconds,
      if (source.audioOrigin case final origin?) 'audioOriginUs': origin.inMicroseconds,
      'params': ParamBindingJson.bindingsToJson(source.bindings),
      if (source.reactivity != AudioReactivity.none) 'reactivity': AudioReactivityJson.toJson(source.reactivity),
      if (source.cueTrackId case final cueTrack?) 'cueTrack': cueTrack,
    };

Map<String, Object?> _clipToJson(Clip clip, {required bool legacy}) => {
      'id': clip.id,
      'source': _sourceToJson(clip.source, legacy: legacy),
      'startUs': clip.start.inMicroseconds,
      'sourceInUs': clip.sourceIn.inMicroseconds,
      'sourceOutUs': clip.sourceOut.inMicroseconds,
      'speed': clip.speed,
      if (clip.loopDuration case final loop?) 'loopDurationUs': loop.inMicroseconds,
      'blend': clip.blend.name,
      'opacity': clip.opacity,
      'fadeInUs': clip.fadeIn.inMicroseconds,
      'fadeOutUs': clip.fadeOut.inMicroseconds,
      'region': _regionToJson(clip.region, legacy: legacy),
      if (clip.isMask) 'mask': true,
      if (clip.reverse) 'reverse': true,
      if (clip.pingPong) 'pingPong': true,
      if (clip.label != ClipLabel.none) 'label': clip.label.name,
    };

/// The region: the version 1 string for a classic region of a [legacy]
/// document, the version 2 object otherwise.
Object _regionToJson(Region region, {required bool legacy}) {
  if (legacy) {
    assert(region.isClassic);
    if (!region.icicles) return 'radioPanels';
    return region.panels is NoPanels ? 'icicles' : 'all';
  }
  return {
    'icicles': region.icicles,
    if (region.columns case final columns?) 'columns': [columns.first, columns.last],
    'panels': switch (region.panels) {
      AllPanels() => 'all',
      NoPanels() => 'none',
      SomePanels(:final indices) => indices.toList()..sort(),
    },
    if (region.pixels case final pixels?) 'pixels': _pixelMaskToJson(pixels),
  };
}

Map<String, Object?> _pixelMaskToJson(PixelMask mask) => {
      'x': mask.xCount,
      'y': mask.yCount,
      'panels': mask.radioPanelsCount,
      'panelPixels': mask.radioPanelPixelCount,
      'bits': base64Encode(mask.bits),
    };

/// A copy of [value] with every map's keys sorted.
Object? _sorted(Object? value) => switch (value) {
      Map<String, Object?>() => {for (final key in value.keys.toList()..sort()) key: _sorted(value[key])},
      List<Object?>() => [for (final item in value) _sorted(item)],
      _ => value,
    };

/// A required part of an element is missing or invalid; the element is
/// dropped.
class _Invalid implements Exception {
  final String message;

  const _Invalid(this.message);
}

/// Typed access to one JSON object, reporting repairs.
class _Fields {
  final Map<String, Object?> json;
  final String path;
  final List<IcprojProblem> problems;

  _Fields(this.json, this.path, this.problems);

  factory _Fields.of(Object? value, String path, List<IcprojProblem> problems) {
    if (value is! Map<String, Object?>) throw _Invalid('$path is not an object.');
    return _Fields(value, path, problems);
  }

  String _at(String key) => '$path.$key';

  String requiredString(String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) throw _Invalid('${_at(key)} is missing or not a non-empty string.');
    return value;
  }

  String string(String key, String fallback) {
    final value = json[key];
    if (value is String) return value;
    if (value != null) _defaulted(key, 'not a string');
    return fallback;
  }

  bool boolean(String key, bool fallback) {
    final value = json[key];
    if (value is bool) return value;
    if (value != null) _defaulted(key, 'not a boolean');
    return fallback;
  }

  int requiredInt(String key) {
    final value = json[key];
    if (value is! num || !value.isFinite) throw _Invalid('${_at(key)} is missing or not a number.');
    return value.round();
  }

  int? optionalInt(String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! num || !value.isFinite) {
      _defaulted(key, 'not a number');
      return null;
    }
    return value.round();
  }

  /// A number clamped to `[min, max]`, [fallback] when missing.
  double number(String key, double fallback, {required double min, required double max}) {
    final value = json[key];
    if (value == null) return fallback;
    if (value is! num || !value.isFinite) {
      _defaulted(key, 'not a number');
      return fallback;
    }
    return clamp(key, value.toDouble(), min, max);
  }

  /// [value] clamped to `[min, max]` (either may be `null`), reported.
  T clamp<T extends num>(String key, T value, T? min, T? max) {
    if (min != null && value < min) {
      problems.add(IcprojProblem(IcprojProblemKind.clampedValue, _at(key), '$value raised to $min.'));
      return min;
    }
    if (max != null && value > max) {
      problems.add(IcprojProblem(IcprojProblemKind.clampedValue, _at(key), '$value lowered to $max.'));
      return max;
    }
    return value;
  }

  /// Microseconds of [key], clamped to at least [min].
  Duration requiredDuration(String key, {int? min}) => Duration(microseconds: clamp(key, requiredInt(key), min, null));

  Duration duration(String key, Duration fallback, {int? min}) {
    final value = optionalInt(key);
    return value == null ? fallback : Duration(microseconds: clamp(key, value, min, null));
  }

  T enumByName<T extends Enum>(String key, List<T> values, T fallback) {
    final value = json[key];
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    if (value != null) _defaulted(key, '"$value" is unknown');
    return fallback;
  }

  List<Object?> list(String key) {
    final value = json[key];
    if (value is List<Object?>) return value;
    if (value != null) _defaulted(key, 'not a list');
    return const [];
  }

  void _defaulted(String key, String reason) =>
      problems.add(IcprojProblem(IcprojProblemKind.defaultedValue, _at(key), '$reason, the default is used.'));
}

class _Decoder {
  final problems = <IcprojProblem>[];
  final _clipIds = <String>{};
  final _transitionIds = <String>{};
  late final OutputSpec _spec;

  IcprojDecodeResult decode(Map<String, Object?> json) {
    final root = _Fields(json, r'$', problems);
    final target = _spec = _target(json['target']);
    var name = root.string('name', '');
    if (name.contains('\u0000')) {
      name = name.replaceAll('\u0000', '');
      problems.add(const IcprojProblem(IcprojProblemKind.defaultedValue, r'$.name', 'NUL characters removed.'));
    }
    final framerate = _framerate(root);

    final tracks = <VisualTrack>[];
    final trackIds = <String>{};
    for (final (index, value) in root.list('tracks').indexed) {
      final path = r'$.tracks' '[$index]';
      try {
        final track = _track(_Fields.of(value, path, problems));
        if (!trackIds.add(track.id)) throw _Invalid('Duplicate track id "${track.id}".');
        tracks.add(track);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedTrack, path, error.message));
      }
    }

    final markers = <Marker>[];
    final markerIds = <String>{};
    for (final (index, value) in root.list('markers').indexed) {
      final path = r'$.markers' '[$index]';
      try {
        final fields = _Fields.of(value, path, problems);
        final marker = Marker(
          id: fields.requiredString('id'),
          at: fields.requiredDuration('atUs', min: 0),
          label: fields.string('label', ''),
          color: fields.enumByName('color', ClipLabel.values, ClipLabel.none),
        );
        if (!markerIds.add(marker.id)) throw _Invalid('Duplicate marker id "${marker.id}".');
        markers.add(marker);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedMarker, path, error.message));
      }
    }

    AudioTrack? audio;
    if (json['audio'] != null) {
      try {
        audio = _audio(_Fields.of(json['audio'], r'$.audio', problems));
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedAudio, r'$.audio', error.message));
      }
    }

    Tempo? tempo;
    if (json['tempo'] != null) {
      try {
        final fields = _Fields.of(json['tempo'], r'$.tempo', problems);
        if (json['tempo'] case {'bpm': final num bpm} when bpm.isFinite) {
          tempo = Tempo(
            bpm: fields.clamp('bpm', bpm.toDouble(), Tempo.minBpm, Tempo.maxBpm),
            firstBeatOffset: fields.duration('firstBeatOffsetUs', Duration.zero),
          );
        } else {
          throw const _Invalid(r'$.tempo.bpm is missing or not a number.');
        }
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedTempo, r'$.tempo', error.message));
      }
    }

    LoopRange? loopRange;
    if (json['loopRange'] != null) {
      try {
        final fields = _Fields.of(json['loopRange'], r'$.loopRange', problems);
        final start = fields.requiredDuration('startUs', min: 0);
        final end = fields.requiredDuration('endUs');
        if (end <= start) throw const _Invalid('endUs is not after startUs.');
        loopRange = LoopRange(start: start, end: end);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.defaultedValue, r'$.loopRange', '${error.message} No range.'));
      }
    }

    final macros = <MacroDef>[];
    final macroIds = <String>{};
    for (final (index, value) in root.list('macros').indexed) {
      final path = r'$.macros' '[$index]';
      try {
        final macro = _macro(_Fields.of(value, path, problems));
        if (!macroIds.add(macro.id)) throw _Invalid('Duplicate macro id "${macro.id}".');
        macros.add(macro);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedMacro, path, error.message));
      } on ArgumentError catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedMacro, path, '${error.message}'));
      }
    }

    final cueTracks = <CueTrack>[];
    final cueTrackIds = <String>{};
    for (final (index, value) in root.list('cueTracks').indexed) {
      final path = r'$.cueTracks' '[$index]';
      try {
        final track = _cueTrack(_Fields.of(value, path, problems), problems);
        if (!cueTrackIds.add(track.id)) throw _Invalid('Duplicate cue track id "${track.id}".');
        cueTracks.add(track);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedCueTrack, path, error.message));
      } on ArgumentError catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedCueTrack, path, '${error.message}'));
      }
    }

    final composition = Composition(
      name: name,
      target: target,
      framerate: framerate,
      tracks: tracks,
      audio: audio,
      tempo: tempo,
      markers: markers,
      loopRange: loopRange,
      macros: macros,
      cueTracks: cueTracks,
    );
    return IcprojDecodeResult(composition, problems);
  }

  /// A cue track; unreadable cues (a missing or negative time, a strength
  /// outside `0..1` is clamped, a repeated id) are dropped one by one.
  static CueTrack _cueTrack(_Fields fields, List<IcprojProblem> problems) {
    final id = fields.requiredString('id');
    final cues = <Cue>[];
    final raw = fields.json['cues'];
    if (raw is Map<String, Object?>) {
      final ids = raw['ids'];
      final us = raw['us'];
      final s = raw['s'];
      if (ids is! List || us is! List || s is! List || ids.length != us.length || us.length != s.length) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedCue, '${fields.path}.cues', 'Columns are unreadable.'));
      } else {
        final seen = <String>{};
        for (var i = 0; i < ids.length; i++) {
          final cueId = ids[i];
          final at = us[i];
          final strength = s[i];
          if (cueId is! String || cueId.isEmpty || !seen.add(cueId) || at is! int || at < 0 || strength is! num) {
            problems.add(IcprojProblem(IcprojProblemKind.droppedCue, '${fields.path}.cues[$i]', 'Unreadable cue.'));
            continue;
          }
          final clamped = strength.isFinite ? strength.toDouble().clamp(0.0, 1.0) : 1.0;
          cues.add(Cue(id: cueId, at: Duration(microseconds: at), strength: clamped));
        }
      }
    } else if (raw != null) {
      fields._defaulted('cues', 'not an object');
    }
    return CueTrack(
      id: id,
      name: fields.string('name', ''),
      color: fields.enumByName('color', ClipLabel.values, ClipLabel.none),
      cues: cues,
    );
  }

  /// The soundtrack: the version 1 `offsetUs` becomes one open-ended
  /// segment; unreadable or overlapping segments are dropped
  /// (`droppedAudio` at the segment's path), the track with them when none
  /// is left.
  AudioTrack _audio(_Fields fields) {
    final path = fields.requiredString('path');
    final gain = fields.number('gain', 1.0, min: 0, max: AudioTrack.maxGain);
    if (fields.json['segments'] == null) {
      return AudioTrack.single(path: path, gain: gain, offset: fields.duration('offsetUs', Duration.zero));
    }
    final segments = <AudioSegment>[];
    final ids = <String>{};
    for (final (index, value) in fields.list('segments').indexed) {
      final segmentPath = '${fields.path}.segments[$index]';
      try {
        final segmentFields = _Fields.of(value, segmentPath, problems);
        final sourceIn = segmentFields.duration('sourceInUs', Duration.zero, min: 0);
        final out = segmentFields.optionalInt('sourceOutUs');
        final segment = AudioSegment(
          id: segmentFields.requiredString('id'),
          start: segmentFields.requiredDuration('startUs', min: 0),
          sourceIn: sourceIn,
          sourceOut: out == null ? null : Duration(microseconds: out),
        );
        if (!ids.add(segment.id)) throw _Invalid('Duplicate audio segment id "${segment.id}".');
        final previous = segments.lastOrNull;
        if (previous != null && (previous.end == null || previous.end! > segment.start)) {
          throw _Invalid('Audio segment "${segment.id}" overlaps "${previous.id}".');
        }
        segments.add(segment);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedAudio, segmentPath, error.message));
      } on ArgumentError catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedAudio, segmentPath, '${error.message}'));
      }
    }
    if (segments.isEmpty) throw const _Invalid('No readable audio segment.');
    return AudioTrack(path: path, gain: gain, segments: segments);
  }

  /// A macro definition; the binding is salvaged by [MacroDef] itself (an
  /// unreadable one falls back to the default with a `droppedBinding`
  /// problem).
  MacroDef _macro(_Fields fields) {
    final id = fields.requiredString('id');
    final name = fields.string('name', id);
    final kind = fields.enumByName('kind', MacroKind.values, MacroKind.number);
    ParamBinding? binding;
    if (fields.json['binding'] != null) {
      binding = ParamBindingJson.fromJson(fields.json['binding']);
      if (binding == null) {
        problems
            .add(IcprojProblem(IcprojProblemKind.droppedBinding, '${fields.path}.binding', 'Not a readable binding.'));
      }
    }
    switch (kind) {
      case MacroKind.number:
        var min = fields.number('min', 0, min: -1e12, max: 1e12);
        var max = fields.number('max', 1, min: -1e12, max: 1e12);
        if (min >= max) {
          fields._defaulted('max', 'not above min');
          (min, max) = (0, 1);
        }
        return MacroDef.number(
          id: id,
          name: name,
          min: min,
          max: max,
          defaultValue: fields.number('default', min, min: min, max: max),
          binding: binding,
        );
      case MacroKind.color:
        Color? color;
        final hex = fields.json['defaultColor'];
        if (hex is String) color = colorFromHex(hex);
        if (hex != null && color == null) fields._defaulted('defaultColor', 'not a color');
        return MacroDef.color(id: id, name: name, defaultValue: color ?? const Color(0xFFFFFFFF), binding: binding);
    }
  }

  OutputSpec _target(Object? value) {
    try {
      final fields = _Fields.of(value, r'$.target', problems);
      return OutputSpec(
        xCount: fields.requiredInt('xCount'),
        yCount: fields.requiredInt('yCount'),
        radioPanelsCount: fields.requiredInt('radioPanelsCount'),
        radioPanelPixelCount: fields.requiredInt('radioPanelPixelCount'),
        version: AnimationVersion.fromValue(fields.requiredInt('animationVersion')),
      );
    } on _Invalid catch (error) {
      throw IcprojException(IcprojErrorKind.invalidProject, 'Invalid target: ${error.message}');
    } on ArgumentError catch (error) {
      throw IcprojException(IcprojErrorKind.invalidProject, 'Invalid target: ${error.message}');
    }
  }

  Framerate _framerate(_Fields root) {
    const fallback = Framerate.fps30;
    final value = root.json['framerate'];
    if (value is! num || !value.isFinite) {
      problems.add(IcprojProblem(IcprojProblemKind.defaultedValue, r'$.framerate', '"$value" is not a number.'));
      return fallback;
    }
    Framerate? nearest;
    for (final candidate in Composition.supportedFramerates) {
      if (nearest == null || (candidate.framesPerSecond - value).abs() < (nearest.framesPerSecond - value).abs()) {
        nearest = candidate;
      }
    }
    if (nearest!.framesPerSecond != value) {
      problems.add(IcprojProblem(
        IcprojProblemKind.clampedValue,
        r'$.framerate',
        '$value fps is not supported, ${nearest.framesPerSecond} fps is used.',
      ));
    }
    return nearest;
  }

  VisualTrack _track(_Fields fields) {
    final id = fields.requiredString('id');
    final clips = <Clip>[];
    for (final (index, value) in fields.list('clips').indexed) {
      final path = '${fields.path}.clips[$index]';
      try {
        final clip = _clip(_Fields.of(value, path, problems));
        if (_clipIds.contains(clip.id)) throw _Invalid('Duplicate clip id "${clip.id}".');
        clips.add(clip);
        _clipIds.add(clip.id);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedClip, path, error.message));
      } on ArgumentError catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedClip, path, '${error.message}'));
      }
    }
    // Clips must not overlap: keep the earlier one.
    clips.sort((a, b) => a.start.compareTo(b.start));
    final kept = <Clip>[];
    for (final clip in clips) {
      if (kept.isNotEmpty && kept.last.end > clip.start) {
        problems.add(IcprojProblem(
          IcprojProblemKind.droppedClip,
          '${fields.path}.clips',
          'Clip "${clip.id}" overlaps clip "${kept.last.id}".',
        ));
        _clipIds.remove(clip.id);
        continue;
      }
      kept.add(clip);
    }

    final transitions = <Transition>[];
    for (final (index, value) in fields.list('transitions').indexed) {
      final path = '${fields.path}.transitions[$index]';
      try {
        final transitionFields = _Fields.of(value, path, problems);
        final transition = Transition(
          id: transitionFields.requiredString('id'),
          fromClipId: transitionFields.requiredString('fromClipId'),
          toClipId: transitionFields.requiredString('toClipId'),
          duration: transitionFields.requiredDuration('durationUs'),
          alignment: transitionFields.enumByName('alignment', TransitionAlignment.values, TransitionAlignment.center),
        );
        if (!_transitionIds.add(transition.id)) throw _Invalid('Duplicate transition id "${transition.id}".');
        transitions.add(transition);
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedTransition, path, error.message));
      } on ArgumentError catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedTransition, path, '${error.message}'));
      }
    }
    final fitted = fitTransitions(kept, transitions);
    for (final issue in fitted.issues) {
      final path = '${fields.path}.transitions[${transitions.indexOf(issue.transition)}]';
      if (issue.dropped) {
        _transitionIds.remove(issue.transition.id);
        problems.add(IcprojProblem(IcprojProblemKind.droppedTransition, path, 'Transition ${issue.kind.name}.'));
      } else {
        problems.add(IcprojProblem(IcprojProblemKind.clampedValue, '$path.durationUs', 'Shortened to the limit.'));
      }
    }

    return VisualTrack(
      id: id,
      name: fields.string('name', ''),
      muted: fields.boolean('muted', false),
      solo: fields.boolean('solo', false),
      locked: fields.boolean('locked', false),
      opacity: fields.number('opacity', 1.0, min: 0, max: 1),
      clips: kept,
      transitions: fitted.kept,
    );
  }

  Clip _clip(_Fields fields) {
    final source = _source(_Fields.of(fields.json['source'], '${fields.path}.source', problems));
    final sourceIn = fields.requiredDuration('sourceInUs', min: 0);
    var sourceOut = fields.requiredDuration('sourceOutUs');
    if (sourceOut <= sourceIn) throw _Invalid('${fields.path}: sourceOutUs is not after sourceInUs.');
    if (source is ParametricRef) {
      if (sourceIn >= source.length) {
        throw _Invalid('${fields.path}: sourceInUs is not before the source length ${source.length}.');
      }
      sourceOut = Duration(
          microseconds: fields.clamp('sourceOutUs', sourceOut.inMicroseconds, null, source.length.inMicroseconds));
    }
    var speed = fields.number('speed', 1.0, min: Clip.minSpeed, max: Clip.maxSpeed);
    if (source is ParametricRef && speed != 1.0) {
      problems.add(IcprojProblem(
          IcprojProblemKind.defaultedValue, '${fields.path}.speed', 'A generator or effect clip plays at speed 1.'));
      speed = 1.0;
    }
    final loop = fields.optionalInt('loopDurationUs');
    Duration? loopDuration;
    if (loop != null && loop <= 0) {
      problems.add(IcprojProblem(
          IcprojProblemKind.defaultedValue,
          '${fields.path}.loopDurationUs',
          'Not positive, '
              'the clip plays once.'));
    } else if (loop != null && source is ParametricRef) {
      problems.add(IcprojProblem(IcprojProblemKind.defaultedValue, '${fields.path}.loopDurationUs',
          'A generator or effect clip never loops.'));
    } else if (loop != null) {
      loopDuration = Duration(microseconds: loop);
    }
    var pingPong = fields.boolean('pingPong', false);
    if (pingPong && loopDuration == null) {
      problems.add(IcprojProblem(
          IcprojProblemKind.defaultedValue, '${fields.path}.pingPong', 'Only a looping clip can ping-pong.'));
      pingPong = false;
    }
    var isMask = fields.boolean('mask', false);
    if (isMask && source is EffectRef) {
      problems.add(
          IcprojProblem(IcprojProblemKind.defaultedValue, '${fields.path}.mask', 'An effect clip cannot be a mask.'));
      isMask = false;
    }
    return Clip(
      id: fields.requiredString('id'),
      source: source,
      start: fields.requiredDuration('startUs', min: 0),
      sourceIn: sourceIn,
      sourceOut: sourceOut,
      speed: speed,
      loopDuration: loopDuration,
      blend: fields.enumByName('blend', BlendMode.values, BlendMode.normal),
      opacity: fields.number('opacity', 1.0, min: 0, max: 1),
      fadeIn: fields.duration('fadeInUs', Duration.zero, min: 0),
      fadeOut: fields.duration('fadeOutUs', Duration.zero, min: 0),
      region: _region(fields),
      isMask: isMask,
      reverse: fields.boolean('reverse', false),
      pingPong: pingPong,
      label: fields.enumByName('label', ClipLabel.values, ClipLabel.none),
    );
  }

  /// The clip region: a version 1 string or a version 2 object; anything
  /// unreadable gives [Region.all] with a problem.
  Region _region(_Fields fields) {
    final value = fields.json['region'];
    switch (value) {
      case null:
        return const Region.all();
      case 'all':
        return const Region.all();
      case 'icicles':
        return const Region.iciclesOnly();
      case 'radioPanels':
        return const Region.panelsOnly();
      case Map<String, Object?>():
        final region = _Fields(value, '${fields.path}.region', problems);
        final icicles = region.boolean('icicles', true);
        ColumnRange? columns;
        final columnsValue = value['columns'];
        if (columnsValue != null) {
          if (columnsValue case [final num first, final num last]
              when first.isFinite && last.isFinite && first >= 0 && last >= first) {
            columns = ColumnRange(first.round(), last.round());
          } else {
            region._defaulted('columns', 'not a [first, last] pair of columns');
          }
        }
        final panelsValue = value['panels'];
        final panels = switch (panelsValue) {
          null || 'all' => const RegionPanels.all(),
          'none' => const RegionPanels.none(),
          List<Object?>() when panelsValue.every((item) => item is num && item.isFinite && item >= 1) =>
            RegionPanels.some({for (final item in panelsValue) (item! as num).round()}),
          _ => () {
              region._defaulted('panels', '"$panelsValue" is not "all", "none" or a list of panel indices');
              return const RegionPanels.all();
            }(),
        };
        final decoded = Region(icicles: icicles, columns: columns, panels: panels, pixels: _pixelMask(region));
        final fitted = decoded.normalized(_spec);
        if (fitted != decoded) {
          problems.add(
              IcprojProblem(IcprojProblemKind.clampedValue, '${fields.path}.region', 'Fitted to the target layout.'));
        }
        return fitted;
      default:
        fields._defaulted('region', '"$value" is unknown');
        return const Region.all();
    }
  }

  /// The region's pixel mask; anything unreadable gives `null` (every
  /// pixel) with a problem.
  PixelMask? _pixelMask(_Fields region) {
    final value = region.json['pixels'];
    if (value == null) return null;
    if (value is! Map<String, Object?>) {
      region._defaulted('pixels', 'not an object');
      return null;
    }
    try {
      final fields = _Fields(value, '${region.path}.pixels', problems);
      final bits = fields.json['bits'];
      if (bits is! String) throw const _Invalid('bits is not a string');
      final Uint8List bytes;
      try {
        bytes = base64Decode(bits);
      } on FormatException catch (error) {
        throw _Invalid('bits is not base64 (${error.message})');
      }
      return PixelMask(
        xCount: fields.requiredInt('x'),
        yCount: fields.requiredInt('y'),
        radioPanelsCount: fields.requiredInt('panels'),
        radioPanelPixelCount: fields.requiredInt('panelPixels'),
        bits: bytes,
      );
    } on _Invalid catch (error) {
      region._defaulted('pixels', 'not a readable pixel mask (${error.message})');
    } on ArgumentError catch (error) {
      region._defaulted('pixels', 'not a readable pixel mask (${error.message})');
    }
    return null;
  }

  /// A clip source: a file (the only kind of version 1, written without
  /// `type`), an image, a drawing, a nested composition, a generator or an
  /// effect.
  SourceRef _source(_Fields fields) {
    final type = fields.json['type'];
    switch (type) {
      case null || 'file':
        return AnimationFileRef(path: fields.requiredString('path'), contentHash: fields.string('contentHash', ''));
      case 'image':
        return _image(fields);
      case 'drawing':
        return _drawing(fields);
      case 'composition':
        return CompositionRef(path: fields.requiredString('path'), contentHash: fields.string('contentHash', ''));
      case 'generator' || 'effect':
        final bindings = <String, ParamBinding>{};
        final params = fields.json['params'];
        if (params is Map<String, Object?>) {
          for (final MapEntry(:key, :value) in params.entries) {
            final binding = ParamBindingJson.fromJson(value);
            if (binding == null) {
              problems.add(IcprojProblem(
                  IcprojProblemKind.droppedBinding, '${fields.path}.params.$key', 'Not a readable binding.'));
            } else {
              bindings[key] = binding;
            }
          }
        } else if (params != null) {
          fields._defaulted('params', 'not an object');
        }
        final seed = fields.optionalInt('seed');
        if (seed == null) fields._defaulted('seed', 'missing');
        var reactivity = AudioReactivity.none;
        if (fields.json['reactivity'] case final Object? raw?) {
          final decoded = AudioReactivityJson.fromJson(raw);
          if (decoded == null) {
            fields._defaulted('reactivity', 'not a readable reactivity');
          } else {
            reactivity = decoded;
          }
        }
        final origin = fields.optionalInt('audioOriginUs');
        final id = fields.requiredString('id');
        final version = fields.clamp<int>('version', fields.requiredInt('version'), 0, null);
        final length = Duration(
          microseconds: fields.clamp('lengthUs', fields.requiredInt('lengthUs'), 1, maxBakeLength.inMicroseconds),
        );
        final audioOrigin = origin == null ? null : Duration(microseconds: origin);
        final cueTrack = fields.json['cueTrack'];
        final cueTrackId = cueTrack is String && cueTrack.isNotEmpty ? cueTrack : null;
        if (cueTrack != null && cueTrackId == null) fields._defaulted('cueTrack', 'not a cue track id');
        if (type == 'effect') {
          return EffectRef(
            effectId: id,
            effectVersion: version,
            bindings: bindings,
            seed: seed ?? 0,
            length: length,
            audioOrigin: audioOrigin,
            reactivity: reactivity,
            cueTrackId: cueTrackId,
          );
        }
        return GeneratorRef(
          generatorId: id,
          generatorVersion: version,
          bindings: bindings,
          seed: seed ?? 0,
          length: length,
          audioOrigin: audioOrigin,
          reactivity: reactivity,
          cueTrackId: cueTrackId,
        );
      default:
        throw _Invalid('${fields.path}.type "$type" is unknown.');
    }
  }

  /// `{type: "image", path | paths, contentHash, fit, panels,
  /// frameDurationUs?}`; an unknown fit or panel mode falls back to the
  /// default, a non-positive frame duration is dropped.
  ImageRef _image(_Fields fields) {
    final List<String> paths;
    final many = fields.json['paths'];
    if (many is List<Object?>) {
      paths = [
        for (final path in many)
          if (path is String && path.isNotEmpty) path
      ];
      if (paths.isEmpty) throw _Invalid('${fields.path}.paths holds no path.');
      if (paths.length != many.length) {
        problems.add(IcprojProblem(
            IcprojProblemKind.defaultedValue, '${fields.path}.paths', 'Unreadable entries were dropped.'));
      }
    } else {
      if (many != null) fields._defaulted('paths', 'not a list');
      paths = [fields.requiredString('path')];
    }
    final frameDuration = fields.optionalInt('frameDurationUs');
    Duration? perFrame;
    if (frameDuration != null) {
      if (frameDuration > 0) {
        perFrame = Duration(microseconds: frameDuration);
      } else {
        fields._defaulted('frameDurationUs', 'not positive');
      }
    }
    return ImageRef(
      paths: paths,
      contentHash: fields.string('contentHash', ''),
      fit: fields.enumByName('fit', ImageFit.values, ImageFit.cover),
      panels: fields.enumByName('panels', ImagePanelMode.values, ImagePanelMode.average),
      frameDuration: perFrame,
    );
  }

  /// `{type: "drawing", id, name, x, y, panels, panelPixels, frames:
  /// [{durationUs, pixels}]}`; an unreadable frame is dropped
  /// ([IcprojProblemKind.droppedFrame]), a drawing without a readable frame
  /// is invalid (its clip is dropped).
  DrawingRef _drawing(_Fields fields) {
    final xCount = fields.clamp<int>('x', fields.requiredInt('x'), 1, null);
    final yCount = fields.clamp<int>('y', fields.requiredInt('y'), 1, null);
    final panels = fields.clamp<int>('panels', fields.requiredInt('panels'), 0, null);
    final panelPixels = fields.clamp<int>('panelPixels', fields.requiredInt('panelPixels'), 0, null);
    final pixelCount = xCount * yCount + panels * panelPixels;
    final frames = <DrawingFrame>[];
    for (final (index, value) in fields.list('frames').indexed) {
      final path = '${fields.path}.frames[$index]';
      try {
        final frame = _Fields.of(value, path, problems);
        final duration = frame.requiredDuration('durationUs', min: DrawingFrame.minDuration.inMicroseconds);
        final pixels = frame.json['pixels'];
        if (pixels is! String) throw _Invalid('$path.pixels is not a string.');
        frames.add(DrawingFrame(duration: duration, pixels: DrawingPixelsCodec.decode(pixels, pixelCount: pixelCount)));
      } on _Invalid catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedFrame, path, error.message));
      } on FormatException catch (error) {
        problems.add(IcprojProblem(IcprojProblemKind.droppedFrame, path, 'Unreadable pixels: ${error.message}'));
      }
    }
    if (frames.isEmpty) throw _Invalid('${fields.path}: no readable frame.');
    return DrawingRef(
      id: fields.requiredString('id'),
      name: fields.string('name', 'Drawing'),
      xCount: xCount,
      yCount: yCount,
      radioPanelsCount: panels,
      radioPanelPixelCount: panelPixels,
      frames: frames,
    );
  }
}

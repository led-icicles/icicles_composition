import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_generators/icicles_generators.dart';

import 'output_spec.dart';

/// What a clip plays: a source `.anim` file ([AnimationFileRef]), an image
/// or image sequence ([ImageRef]), a drawing stored in the project
/// ([DrawingRef]), another project ([CompositionRef]), a generator
/// configuration ([GeneratorRef]) or an effect configuration ([EffectRef],
/// an adjustment layer over the tracks below).
///
/// A file, image, drawing or nested-composition source is *indexed*: the
/// application supplies its `AnimationIndex` (decoded, scaled or rendered)
/// and its `SourceInfo`; the edit operations treat them alike.
///
/// Clips sharing a source share one [SourceRef], so it is the key of the
/// sources map passed to the compositor; two equal refs are one source.
sealed class SourceRef extends Equatable {
  const SourceRef();

  /// Short name for messages: the file path, the drawing name, the
  /// generator id or the effect id.
  String get label;

  /// Whether the source is played from an index the application supplies
  /// (a file, image, drawing or nested composition) — as opposed to a
  /// [ParametricRef], which the application bakes or runs itself.
  bool get isIndexed => this is! ParametricRef;
}

/// Reference to a source `.anim` file.
///
/// [path] is stored as given (relative to the project file by convention);
/// resolving it is the job of the application. [contentHash] is an opaque
/// fingerprint of the file content computed by the application; a source
/// whose current content no longer matches it is treated as offline.
final class AnimationFileRef extends SourceRef {
  /// Path of the `.anim` file, relative to the project file by convention.
  final String path;

  /// Opaque fingerprint of the file content.
  final String contentHash;

  AnimationFileRef({required this.path, required this.contentHash}) {
    if (path.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Must not be empty.');
    }
  }

  AnimationFileRef copyWith({String? path, String? contentHash}) =>
      AnimationFileRef(path: path ?? this.path, contentHash: contentHash ?? this.contentHash);

  @override
  String get label => path;

  @override
  List<Object?> get props => [path, contentHash];

  @override
  String toString() => 'AnimationFileRef($path, $contentHash)';
}

/// A source made of code with parameters ([GeneratorRef] or [EffectRef]):
/// parameter bindings, a seed, a length on the frame grid, the universal
/// audio reactivity and an optional anchor on the audio clock. Clips of such
/// sources always play at speed 1 and never loop; the edit operations treat
/// both kinds alike.
sealed class ParametricRef extends SourceRef {
  /// Id of the generator or effect.
  String get programId;

  /// Version of the generator or effect the clip was made with.
  int get programVersion;

  /// Parameter bindings by parameter id; unmodifiable. Parameters without a
  /// binding use their defaults.
  final Map<String, ParamBinding> bindings;

  /// Seed of the random source.
  final int seed;

  /// Length of the run: generator/effect time runs over `[0, length)`; the
  /// clip's `sourceOut` never exceeds it. Positive, at most [maxBakeLength].
  final Duration length;

  /// Song time at generator/effect time 0, non-`null` only when the program,
  /// a binding or the reactivity reads the audio. The edit operations keep
  /// it equal to `clip.start − clip.sourceIn − audio.offset`
  /// (`audioOriginFor`).
  final Duration? audioOrigin;

  /// The universal audio reactivity applied around the program
  /// (`BakeRequest.reactivity`); [AudioReactivity.none] by default. A ref
  /// with an active reactivity is audio-bound ([audioOrigin] set).
  final AudioReactivity reactivity;

  /// The id of the cue track the clip's cue triggers fire on; `null` = the
  /// composition's first cue track (see `Composition.cueTrackFor`).
  final String? cueTrackId;

  ParametricRef({
    required Map<String, ParamBinding> bindings,
    required this.seed,
    required this.length,
    required this.audioOrigin,
    this.reactivity = AudioReactivity.none,
    this.cueTrackId,
  }) : bindings = Map.unmodifiable(bindings) {
    if (length <= Duration.zero || length > maxBakeLength) {
      throw ArgumentError.value(length, 'length', 'Must be positive and at most $maxBakeLength.');
    }
  }

  /// Whether the program reads the audio clock, i.e. [audioOrigin] is set.
  bool get usesAudio => audioOrigin != null;

  /// A copy with the given fields replaced; [removeAudioOrigin] /
  /// [removeCueTrackId] set [audioOrigin] / [cueTrackId] to `null`.
  ParametricRef copyWith({
    Map<String, ParamBinding>? bindings,
    int? seed,
    Duration? length,
    Duration? audioOrigin,
    bool removeAudioOrigin = false,
    AudioReactivity? reactivity,
    String? cueTrackId,
    bool removeCueTrackId = false,
  });

  @override
  String get label => programId;

  @override
  List<Object?> get props => [
        programId,
        programVersion,
        seed,
        length,
        audioOrigin,
        reactivity,
        cueTrackId,
        // Map contents in a stable order, so equal bindings compare equal.
        for (final key in bindings.keys.toList()..sort()) (key, bindings[key]),
      ];
}

/// A generator configuration, baked by the application into an animation of
/// [length] at the composition target layout and indexed like a file.
///
/// Equal refs (same generator, bindings, seed, length and audio origin)
/// share one bake; a parameter edit creates a new ref for that clip only.
final class GeneratorRef extends ParametricRef {
  /// Id of the generator ([GeneratorInfo.id]).
  final String generatorId;

  /// Version of the generator the clip was made with
  /// ([GeneratorInfo.version]).
  final int generatorVersion;

  GeneratorRef({
    required this.generatorId,
    required this.generatorVersion,
    super.bindings = const {},
    required super.seed,
    required super.length,
    super.audioOrigin,
    super.reactivity,
    super.cueTrackId,
  }) {
    if (generatorId.isEmpty) {
      throw ArgumentError.value(generatorId, 'generatorId', 'Must not be empty.');
    }
    if (generatorVersion < 0) {
      throw ArgumentError.value(generatorVersion, 'generatorVersion', 'Must not be negative.');
    }
  }

  @override
  String get programId => generatorId;

  @override
  int get programVersion => generatorVersion;

  @override
  GeneratorRef copyWith({
    String? generatorId,
    int? generatorVersion,
    Map<String, ParamBinding>? bindings,
    int? seed,
    Duration? length,
    Duration? audioOrigin,
    bool removeAudioOrigin = false,
    AudioReactivity? reactivity,
    String? cueTrackId,
    bool removeCueTrackId = false,
  }) =>
      GeneratorRef(
        generatorId: generatorId ?? this.generatorId,
        generatorVersion: generatorVersion ?? this.generatorVersion,
        bindings: bindings ?? this.bindings,
        seed: seed ?? this.seed,
        length: length ?? this.length,
        audioOrigin: removeAudioOrigin ? null : (audioOrigin ?? this.audioOrigin),
        reactivity: reactivity ?? this.reactivity,
        cueTrackId: removeCueTrackId ? null : (cueTrackId ?? this.cueTrackId),
      );

  @override
  String toString() => 'GeneratorRef($generatorId v$generatorVersion, seed $seed, $length'
      '${audioOrigin == null ? '' : ', audio at $audioOrigin'}${reactivity.isActive ? ', $reactivity' : ''})';
}

/// An effect configuration: an *adjustment layer*. While its clip is
/// active, the compositor runs the effect over everything the tracks below
/// have drawn so far and continues with the result; the clip's opacity and
/// fades mix the processed picture with the input, its region limits where
/// the effect is applied (elsewhere the input passes through). The
/// application runs the effect per frame through an `EffectHost`.
///
/// Equal refs (same effect, bindings, seed, length and audio origin) are
/// one source; a parameter edit creates a new ref for that clip only.
final class EffectRef extends ParametricRef {
  /// Id of the effect (`EffectInfo.id`).
  final String effectId;

  /// Version of the effect the clip was made with (`EffectInfo.version`).
  final int effectVersion;

  EffectRef({
    required this.effectId,
    required this.effectVersion,
    super.bindings = const {},
    required super.seed,
    required super.length,
    super.audioOrigin,
    super.reactivity,
    super.cueTrackId,
  }) {
    if (effectId.isEmpty) {
      throw ArgumentError.value(effectId, 'effectId', 'Must not be empty.');
    }
    if (effectVersion < 0) {
      throw ArgumentError.value(effectVersion, 'effectVersion', 'Must not be negative.');
    }
  }

  @override
  String get programId => effectId;

  @override
  int get programVersion => effectVersion;

  @override
  EffectRef copyWith({
    String? effectId,
    int? effectVersion,
    Map<String, ParamBinding>? bindings,
    int? seed,
    Duration? length,
    Duration? audioOrigin,
    bool removeAudioOrigin = false,
    AudioReactivity? reactivity,
    String? cueTrackId,
    bool removeCueTrackId = false,
  }) =>
      EffectRef(
        effectId: effectId ?? this.effectId,
        effectVersion: effectVersion ?? this.effectVersion,
        bindings: bindings ?? this.bindings,
        seed: seed ?? this.seed,
        length: length ?? this.length,
        audioOrigin: removeAudioOrigin ? null : (audioOrigin ?? this.audioOrigin),
        reactivity: reactivity ?? this.reactivity,
        cueTrackId: removeCueTrackId ? null : (cueTrackId ?? this.cueTrackId),
      );

  @override
  String toString() => 'EffectRef($effectId v$effectVersion, seed $seed, $length'
      '${audioOrigin == null ? '' : ', audio at $audioOrigin'}${reactivity.isActive ? ', $reactivity' : ''})';
}

/// How an image is scaled onto the target grid (an [ImageRef]).
enum ImageFit {
  /// Scaled to fill the grid, cropped centered where the aspect differs.
  cover,

  /// Scaled to fit inside the grid, black bars where the aspect differs.
  contain,

  /// Scaled to the grid independently in both directions.
  stretch;

  static ImageFit? fromName(String? name) => values.where((fit) => fit.name == name).firstOrNull;
}

/// What the radio panels show for an image or a nested source.
enum ImagePanelMode {
  /// Each panel shows the average color of the frame.
  average,

  /// Panels black.
  off;

  static ImagePanelMode? fromName(String? name) => values.where((mode) => mode.name == name).firstOrNull;
}

/// Reference to one image file (PNG/JPEG: a still; GIF/APNG: an animation
/// with its own frame timings) or to a sequence of image files played in
/// the given order (a frame per file).
///
/// The application decodes the files and scales them onto the composition
/// target with [fit] (an area-averaging downscale), so the index it
/// supplies always has the target layout; the radio panels follow
/// [panels]. Like a file source, the clip may be trimmed, sped up, looped
/// and reversed. [contentHash] fingerprints the file contents (all files of
/// a sequence) like [AnimationFileRef.contentHash].
final class ImageRef extends SourceRef {
  /// The default frame duration of a sequence (and of an animated image
  /// frame without a timing): 1/30 s.
  static const defaultFrameDuration = Duration(microseconds: 33333);

  /// The image files, in playback order; one for a single image.
  final List<String> paths;

  /// Opaque fingerprint of the file contents.
  final String contentHash;
  final ImageFit fit;
  final ImagePanelMode panels;

  /// Duration of every frame of a sequence or an animated image; `null`
  /// keeps the image's own timings (a sequence then plays at
  /// [defaultFrameDuration]). Ignored by a still.
  final Duration? frameDuration;

  ImageRef({
    required List<String> paths,
    required this.contentHash,
    this.fit = ImageFit.cover,
    this.panels = ImagePanelMode.average,
    this.frameDuration,
  }) : paths = List.unmodifiable(paths) {
    if (paths.isEmpty) throw ArgumentError.value(paths, 'paths', 'Must not be empty.');
    if (paths.any((path) => path.isEmpty)) throw ArgumentError.value(paths, 'paths', 'Must not hold an empty path.');
    final duration = frameDuration;
    if (duration != null && duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'frameDuration', 'Must be positive.');
    }
  }

  /// A single image.
  ImageRef.single({
    required String path,
    required String contentHash,
    ImageFit fit = ImageFit.cover,
    ImagePanelMode panels = ImagePanelMode.average,
    Duration? frameDuration,
  }) : this(paths: [path], contentHash: contentHash, fit: fit, panels: panels, frameDuration: frameDuration);

  /// The first (or only) file.
  String get path => paths.first;

  /// Whether this is a sequence of files (a frame per file).
  bool get isSequence => paths.length > 1;

  /// A copy with the given fields replaced; [clearFrameDuration] sets
  /// [frameDuration] to `null`.
  ImageRef copyWith({
    List<String>? paths,
    String? contentHash,
    ImageFit? fit,
    ImagePanelMode? panels,
    Duration? frameDuration,
    bool clearFrameDuration = false,
  }) =>
      ImageRef(
        paths: paths ?? this.paths,
        contentHash: contentHash ?? this.contentHash,
        fit: fit ?? this.fit,
        panels: panels ?? this.panels,
        frameDuration: clearFrameDuration ? null : (frameDuration ?? this.frameDuration),
      );

  @override
  String get label => path;

  @override
  List<Object?> get props => [paths, contentHash, fit, panels, frameDuration];

  @override
  String toString() => 'ImageRef(${paths.join(', ')}, $contentHash, ${fit.name}, panels ${panels.name}'
      '${frameDuration == null ? '' : ', $frameDuration per frame'})';
}

/// One hand-drawn frame of a [DrawingRef]: its duration and its RGB pixels
/// — the icicle pixels (column-major, `x · yCount + y`) followed by the
/// radio panel pixels (panel 1 first, then its LEDs in order), 3 bytes
/// each.
final class DrawingFrame extends Equatable {
  /// Shortest frame: 1 ms.
  static const minDuration = Duration(milliseconds: 1);

  final Duration duration;
  final Uint8List pixels;

  DrawingFrame({required this.duration, required Uint8List pixels}) : pixels = Uint8List.fromList(pixels) {
    if (duration < minDuration) throw ArgumentError.value(duration, 'duration', 'Must be at least $minDuration.');
    if (pixels.length % 3 != 0) throw ArgumentError.value(pixels.length, 'pixels', 'Must hold whole RGB triples.');
  }

  /// A black frame of [pixelCount] pixels.
  DrawingFrame.blank({required this.duration, required int pixelCount}) : pixels = Uint8List(pixelCount * 3) {
    if (duration < minDuration) throw ArgumentError.value(duration, 'duration', 'Must be at least $minDuration.');
    if (pixelCount < 0) throw ArgumentError.value(pixelCount, 'pixelCount', 'Must not be negative.');
  }

  /// Number of pixels (icicle and panel pixels together).
  int get pixelCount => pixels.length ~/ 3;

  /// The color of pixel [index].
  Color colorAt(int index) => Color.fromRGB(pixels[index * 3], pixels[index * 3 + 1], pixels[index * 3 + 2]);

  /// A copy with the pixels of [colors] (by index) replaced.
  DrawingFrame withPixels(Map<int, Color> colors) {
    final next = Uint8List.fromList(pixels);
    for (final MapEntry(key: index, value: color) in colors.entries) {
      RangeError.checkValidIndex(index, this, 'index', pixelCount);
      next[index * 3] = color.red;
      next[index * 3 + 1] = color.green;
      next[index * 3 + 2] = color.blue;
    }
    return DrawingFrame(duration: duration, pixels: next);
  }

  DrawingFrame copyWith({Duration? duration, Uint8List? pixels}) =>
      DrawingFrame(duration: duration ?? this.duration, pixels: pixels ?? this.pixels);

  @override
  List<Object?> get props => [duration, pixels];
}

/// A clip drawn by hand, frame by frame, stored inside the project: its
/// frames hold the pixels of the layout it was drawn for ([xCount] ×
/// [yCount] icicle pixels + [radioPanelsCount] × [radioPanelPixelCount]
/// panel pixels). [toViews] makes the views an `AnimationIndex` is built
/// from; the clip plays like a file clip (trim, speed, loop, reverse).
///
/// Every edit of a drawing makes a new ref (refs are values), so the clip's
/// source changes with each stroke; [id] tells the drawings apart in the
/// media bin regardless of their content.
final class DrawingRef extends SourceRef {
  /// Default duration of a new frame: 1 s.
  static const defaultFrameDuration = Duration(seconds: 1);

  final String id;
  final String name;
  final int xCount;
  final int yCount;
  final int radioPanelsCount;
  final int radioPanelPixelCount;

  /// At least one frame; every frame has [pixelCount] pixels.
  final List<DrawingFrame> frames;

  DrawingRef({
    required this.id,
    this.name = 'Drawing',
    required this.xCount,
    required this.yCount,
    required this.radioPanelsCount,
    required this.radioPanelPixelCount,
    required List<DrawingFrame> frames,
  }) : frames = List.unmodifiable(frames) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (xCount <= 0 || yCount <= 0) throw ArgumentError('The grid must have at least one pixel.');
    if (radioPanelsCount < 0 || radioPanelPixelCount < 0) throw ArgumentError('Panel counts must not be negative.');
    if (frames.isEmpty) throw ArgumentError.value(frames, 'frames', 'Must hold at least one frame.');
    for (final frame in frames) {
      if (frame.pixelCount != pixelCount) {
        throw ArgumentError.value(frame.pixelCount, 'frames', 'Every frame must hold $pixelCount pixels.');
      }
    }
  }

  /// A one-frame black drawing of the given layout.
  DrawingRef.blank({
    required String id,
    String name = 'Drawing',
    required int xCount,
    required int yCount,
    required int radioPanelsCount,
    required int radioPanelPixelCount,
    Duration frameDuration = defaultFrameDuration,
  }) : this(
          id: id,
          name: name,
          xCount: xCount,
          yCount: yCount,
          radioPanelsCount: radioPanelsCount,
          radioPanelPixelCount: radioPanelPixelCount,
          frames: [
            DrawingFrame.blank(
              duration: frameDuration,
              pixelCount: xCount * yCount + radioPanelsCount * radioPanelPixelCount,
            ),
          ],
        );

  /// Icicle pixels of a frame.
  int get iciclePixelCount => xCount * yCount;

  /// Pixels of a frame: the icicle pixels followed by the panel pixels.
  int get pixelCount => iciclePixelCount + radioPanelsCount * radioPanelPixelCount;

  /// Index into a frame's pixels of LED [led] of the 1-based [panel].
  int panelPixelIndex(int panel, int led) => iciclePixelCount + (panel - 1) * radioPanelPixelCount + led;

  /// Length of one pass: the sum of the frame durations.
  Duration get duration => frames.fold(Duration.zero, (sum, frame) => sum + frame.duration);

  /// The layout as an animation header.
  AnimationHeader get header => AnimationHeader(
        name: name,
        xCount: xCount,
        yCount: yCount,
        radioPanelsCount: radioPanelsCount,
        radioPanelPixelCount: radioPanelPixelCount,
      );

  /// Whether the drawing has the layout of [target].
  bool fits(OutputSpec target) =>
      target.xCount == xCount &&
      target.yCount == yCount &&
      target.radioPanelsCount == radioPanelsCount &&
      target.radioPanelPixelCount == radioPanelPixelCount;

  /// The frames as views (one per frame, in order).
  List<AnimationView> toViews() => [
        for (final frame in frames)
          AnimationView(
            VisualFrame(
              duration: frame.duration,
              pixels: List.generate(iciclePixelCount, frame.colorAt, growable: false),
            ),
            [
              for (var panel = 1; panel <= radioPanelsCount; panel++)
                RadioPanelView(
                  panel,
                  List.generate(radioPanelPixelCount, (led) => frame.colorAt(panelPixelIndex(panel, led)),
                      growable: false),
                ),
            ],
          ),
      ];

  DrawingRef copyWith({String? id, String? name, List<DrawingFrame>? frames}) => DrawingRef(
        id: id ?? this.id,
        name: name ?? this.name,
        xCount: xCount,
        yCount: yCount,
        radioPanelsCount: radioPanelsCount,
        radioPanelPixelCount: radioPanelPixelCount,
        frames: frames ?? this.frames,
      );

  @override
  String get label => name;

  @override
  List<Object?> get props => [id, name, xCount, yCount, radioPanelsCount, radioPanelPixelCount, frames];

  @override
  String toString() => 'DrawingRef($id "$name", ${xCount}x$yCount + $radioPanelsCount×$radioPanelPixelCount, '
      '${frames.length} frames, $duration)';
}

/// Reference to another project (`.icproj` or `.icpack`) played as one clip
/// (a nested composition). The application renders it at the parent
/// composition's target (a project of another layout is offline with
/// `layoutMismatch`), guarding against cycles; the result is indexed like a
/// file, so the clip may be trimmed, sped up, looped and reversed.
/// [contentHash] fingerprints the project file like
/// [AnimationFileRef.contentHash].
final class CompositionRef extends SourceRef {
  /// Path of the project file, relative to the parent project by convention.
  final String path;

  /// Opaque fingerprint of the project file content.
  final String contentHash;

  CompositionRef({required this.path, required this.contentHash}) {
    if (path.isEmpty) throw ArgumentError.value(path, 'path', 'Must not be empty.');
  }

  CompositionRef copyWith({String? path, String? contentHash}) =>
      CompositionRef(path: path ?? this.path, contentHash: contentHash ?? this.contentHash);

  @override
  String get label => path;

  @override
  List<Object?> get props => [path, contentHash];

  @override
  String toString() => 'CompositionRef($path, $contentHash)';
}

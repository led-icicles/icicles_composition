import 'package:equatable/equatable.dart';
import 'package:icicles_generators/icicles_generators.dart';

/// What a clip plays: a source `.anim` file ([AnimationFileRef]), a
/// generator configuration ([GeneratorRef]) or an effect configuration
/// ([EffectRef], an adjustment layer over the tracks below).
///
/// Clips sharing a source share one [SourceRef], so it is the key of the
/// sources map passed to the compositor; two equal refs are one source.
sealed class SourceRef extends Equatable {
  const SourceRef();

  /// Short name for messages: the file path, the generator id or the
  /// effect id.
  String get label;
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
/// parameter bindings, a seed, a length on the frame grid and an optional
/// anchor on the audio clock. Clips of such sources always play at speed 1
/// and never loop; the edit operations treat both kinds alike.
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

  /// Song time at generator/effect time 0, non-`null` only when the program
  /// or a binding reads the audio. The edit operations keep it equal to
  /// `clip.start − clip.sourceIn − audio.offset` (`audioOriginFor`).
  final Duration? audioOrigin;

  ParametricRef({
    required Map<String, ParamBinding> bindings,
    required this.seed,
    required this.length,
    required this.audioOrigin,
  }) : bindings = Map.unmodifiable(bindings) {
    if (length <= Duration.zero || length > maxBakeLength) {
      throw ArgumentError.value(length, 'length', 'Must be positive and at most $maxBakeLength.');
    }
  }

  /// Whether the program reads the audio clock, i.e. [audioOrigin] is set.
  bool get usesAudio => audioOrigin != null;

  /// A copy with the given fields replaced; [removeAudioOrigin] sets
  /// [audioOrigin] to `null`.
  ParametricRef copyWith({
    Map<String, ParamBinding>? bindings,
    int? seed,
    Duration? length,
    Duration? audioOrigin,
    bool removeAudioOrigin = false,
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
  }) =>
      GeneratorRef(
        generatorId: generatorId ?? this.generatorId,
        generatorVersion: generatorVersion ?? this.generatorVersion,
        bindings: bindings ?? this.bindings,
        seed: seed ?? this.seed,
        length: length ?? this.length,
        audioOrigin: removeAudioOrigin ? null : (audioOrigin ?? this.audioOrigin),
      );

  @override
  String toString() => 'GeneratorRef($generatorId v$generatorVersion, seed $seed, $length'
      '${audioOrigin == null ? '' : ', audio at $audioOrigin'})';
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
  }) =>
      EffectRef(
        effectId: effectId ?? this.effectId,
        effectVersion: effectVersion ?? this.effectVersion,
        bindings: bindings ?? this.bindings,
        seed: seed ?? this.seed,
        length: length ?? this.length,
        audioOrigin: removeAudioOrigin ? null : (audioOrigin ?? this.audioOrigin),
      );

  @override
  String toString() => 'EffectRef($effectId v$effectVersion, seed $seed, $length'
      '${audioOrigin == null ? '' : ', audio at $audioOrigin'})';
}

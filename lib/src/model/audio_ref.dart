import 'package:equatable/equatable.dart';

/// The music track of a composition.
class AudioRef extends Equatable {
  /// Highest allowed [gain].
  static const maxGain = 4.0;

  /// Path of the audio file, relative to the project file by convention.
  final String path;

  /// Linear volume factor in `[0, maxGain]`; `1` keeps the file volume.
  final double gain;

  /// Timeline time at which the audio file starts. A negative offset skips
  /// the beginning of the file.
  final Duration offset;

  AudioRef({required this.path, this.gain = 1.0, this.offset = Duration.zero}) {
    if (path.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Must not be empty.');
    }
    if (!gain.isFinite || gain < 0 || gain > maxGain) {
      throw ArgumentError.value(gain, 'gain', 'Must be in [0, $maxGain].');
    }
  }

  AudioRef copyWith({String? path, double? gain, Duration? offset}) =>
      AudioRef(path: path ?? this.path, gain: gain ?? this.gain, offset: offset ?? this.offset);

  @override
  List<Object?> get props => [path, gain, offset];
}

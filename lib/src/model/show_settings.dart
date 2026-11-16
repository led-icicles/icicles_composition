import 'package:equatable/equatable.dart';

/// How many flashes a second the show checks allow: [standard] (3 a second,
/// the photosensitive epilepsy guideline), a custom ceiling, or [off] (no
/// check). Only what the checks report — no program changes its output.
class FlashLimit extends Equatable {
  /// Highest custom ceiling.
  static const maxPerSecondLimit = 30;

  /// The ceiling, `null` = no check.
  final int? maxPerSecond;

  /// Throws an [ArgumentError] for a ceiling outside `1..maxPerSecondLimit`.
  FlashLimit(int this.maxPerSecond) {
    if (maxPerSecond! < 1 || maxPerSecond! > maxPerSecondLimit) {
      throw ArgumentError.value(maxPerSecond, 'maxPerSecond', 'Must be in [1, $maxPerSecondLimit].');
    }
  }

  const FlashLimit._(this.maxPerSecond);

  /// 3 flashes a second.
  static const standard = FlashLimit._(3);

  /// No flash check.
  static const off = FlashLimit._(null);

  bool get isOff => maxPerSecond == null;

  /// Whether [flashesPerSecond] breaks the limit.
  bool exceededBy(int flashesPerSecond) => maxPerSecond != null && flashesPerSecond > maxPerSecond!;

  @override
  List<Object?> get props => [maxPerSecond];
}

/// Where the song's sections come from.
enum SectionSource {
  /// The structure model when its analysis exists, else [energy].
  auto,

  /// The structure model's labelled sections.
  structure,

  /// Energy novelty over the bars.
  energy,

  /// The composition's markers: every marker starts a section named by its
  /// label.
  markers,
}

/// Physical spacing of the installation (centimetres), so shapes drawn in
/// pixels can be corrected for the real aspect: icicles are usually much
/// further apart than the LEDs along one.
class PhysicalGeometry extends Equatable {
  /// The real installation: 1 m strips of 30 LEDs, icicles about 50 cm apart.
  static final installation = PhysicalGeometry(icicleSpacingCm: 50, ledPitchCm: 100 / 30);

  /// Distance between neighbouring icicles.
  final double icicleSpacingCm;

  /// Distance between neighbouring LEDs of one icicle.
  final double ledPitchCm;

  /// Throws an [ArgumentError] for a spacing that is not positive and finite.
  PhysicalGeometry({required this.icicleSpacingCm, required this.ledPitchCm}) {
    for (final (name, value) in [('icicleSpacingCm', icicleSpacingCm), ('ledPitchCm', ledPitchCm)]) {
      if (!value.isFinite || value <= 0) throw ArgumentError.value(value, name, 'Must be positive.');
    }
  }

  /// How many LED pitches one icicle step is (x : y of a pixel).
  double get pixelAspect => icicleSpacingCm / ledPitchCm;

  @override
  List<Object?> get props => [icicleSpacingCm, ledPitchCm];
}

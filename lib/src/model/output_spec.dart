import 'package:equatable/equatable.dart';
import 'package:icicles_animation_dart/icicles_animation_dart.dart';

/// The hardware layout a composition renders for: the icicles grid, the
/// radio panels and the `.anim` format version of the export.
class OutputSpec extends Equatable {
  /// Number of icicles (columns).
  final int xCount;

  /// LEDs per icicle (rows).
  final int yCount;

  final int radioPanelsCount;

  /// LEDs per radio panel; `1` for [AnimationVersion.v1].
  final int radioPanelPixelCount;

  /// Format version of the exported animation.
  final AnimationVersion version;

  /// Throws an [ArgumentError] for a layout the `.anim` format cannot hold.
  OutputSpec({
    required this.xCount,
    required this.yCount,
    this.radioPanelsCount = 0,
    this.radioPanelPixelCount = 1,
    this.version = AnimationVersion.v2,
  }) {
    // The header constructor holds the format limits.
    toHeader(name: '');
    if (!version.supportsRadioVisualFrames && radioPanelPixelCount != 1) {
      throw ArgumentError.value(
        radioPanelPixelCount,
        'radioPanelPixelCount',
        'Version ${version.name} supports only single-pixel radio panels.',
      );
    }
  }

  /// The layout and version of [header].
  factory OutputSpec.fromHeader(AnimationHeader header) => OutputSpec(
        xCount: header.xCount,
        yCount: header.yCount,
        radioPanelsCount: header.radioPanelsCount,
        radioPanelPixelCount: header.radioPanelPixelCount,
        version: header.version,
      );

  /// Number of icicles grid pixels.
  int get pixelsCount => xCount * yCount;

  /// A header with this layout.
  AnimationHeader toHeader({required String name, int loopsCount = 1}) => AnimationHeader(
        name: name,
        xCount: xCount,
        yCount: yCount,
        loopsCount: loopsCount,
        version: version,
        radioPanelsCount: radioPanelsCount,
        radioPanelPixelCount: radioPanelPixelCount,
      );

  /// Whether an animation with [header] can be placed on this output.
  bool acceptsLayoutOf(AnimationHeader header) => toHeader(name: '').hasSameLayout(header);

  /// Whether [view] has the shape of this output: pixel count, radio panel
  /// indexes `1..radioPanelsCount` and pixels per panel.
  bool matchesView(AnimationView view) {
    if (view.frame.pixels.length != pixelsCount) return false;
    if (view.radioPanels.length != radioPanelsCount) return false;
    for (final panel in view.radioPanels) {
      if (panel.index < 1 || panel.index > radioPanelsCount) return false;
      if (panel.colors.length != radioPanelPixelCount) return false;
    }
    return true;
  }

  OutputSpec copyWith({
    int? xCount,
    int? yCount,
    int? radioPanelsCount,
    int? radioPanelPixelCount,
    AnimationVersion? version,
  }) =>
      OutputSpec(
        xCount: xCount ?? this.xCount,
        yCount: yCount ?? this.yCount,
        radioPanelsCount: radioPanelsCount ?? this.radioPanelsCount,
        radioPanelPixelCount: radioPanelPixelCount ?? this.radioPanelPixelCount,
        version: version ?? this.version,
      );

  @override
  List<Object?> get props => [xCount, yCount, radioPanelsCount, radioPanelPixelCount, version];
}

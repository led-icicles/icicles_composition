import 'package:icicles_animation_dart/icicles_animation_dart.dart';

import '../model/source_ref.dart';

/// What the edit operations need to know about a source animation.
class SourceInfo {
  /// Layout of the source, checked against the composition target.
  final AnimationHeader header;

  /// Length of one pass of the source; trims are clamped to it.
  final Duration duration;

  const SourceInfo({required this.header, required this.duration});

  /// The header and single-pass length of [animation].
  SourceInfo.of(Animation animation)
      : header = animation.header,
        duration = animation.duration;

  /// The layout and length of a drawing.
  SourceInfo.ofDrawing(DrawingRef drawing)
      : header = drawing.header,
        duration = drawing.duration;
}

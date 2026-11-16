import 'package:equatable/equatable.dart';

/// Where one object of the installation sits on the application's canvas:
/// the icicles grid or one radio panel. Canvas units are the application's
/// (logical pixels of the LED preview); [rotation] is in radians about the
/// center.
class StagePlacement extends Equatable {
  /// `0` for the icicles grid, `1..` for a radio panel (1-based, like the
  /// radio addresses).
  final int index;
  final double cx;
  final double cy;
  final double width;
  final double height;
  final double rotation;

  /// The object's drawn shape (`"rect"`); kept as a name so newer shapes
  /// pass through untouched.
  final String shape;

  /// Throws an [ArgumentError] for a negative [index], a non-finite number,
  /// a size that is not positive or an empty [shape].
  StagePlacement({
    required this.index,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.shape = 'rect',
  }) {
    if (index < 0) throw ArgumentError.value(index, 'index', 'Must not be negative.');
    for (final (name, value) in [
      ('cx', cx),
      ('cy', cy),
      ('width', width),
      ('height', height),
      ('rotation', rotation)
    ]) {
      if (!value.isFinite) throw ArgumentError.value(value, name, 'Must be finite.');
    }
    if (width <= 0) throw ArgumentError.value(width, 'width', 'Must be positive.');
    if (height <= 0) throw ArgumentError.value(height, 'height', 'Must be positive.');
    if (shape.isEmpty) throw ArgumentError.value(shape, 'shape', 'Must not be empty.');
  }

  @override
  List<Object?> get props => [index, cx, cy, width, height, rotation, shape];
}

/// How the installation is arranged on screen for this composition: the
/// placements of the icicles grid and the radio panels in the preview. Only
/// the look of the preview — rendering ignores it. Sparse: a missing [grid]
/// or panel keeps the application's computed default.
class StageLayout extends Equatable {
  /// The layout's name in the application's layout library.
  final String name;

  /// Index 0, or `null` for the natural default.
  final StagePlacement? grid;

  /// Sorted by index; indices unique and at least 1.
  final List<StagePlacement> panels;

  /// Throws an [ArgumentError] for a [grid] whose index is not 0, a panel
  /// index below 1 or a repeated panel index.
  StageLayout({this.name = '', this.grid, List<StagePlacement> panels = const []})
      : panels = List.unmodifiable(List<StagePlacement>.of(panels)..sort((a, b) => a.index.compareTo(b.index))) {
    if (grid case final grid? when grid.index != 0) {
      throw ArgumentError.value(grid.index, 'grid.index', 'Must be 0.');
    }
    final seen = <int>{};
    for (final panel in this.panels) {
      if (panel.index < 1) throw ArgumentError.value(panel.index, 'panels.index', 'Must be at least 1.');
      if (!seen.add(panel.index)) throw ArgumentError('Duplicate panel index ${panel.index}.');
    }
  }

  /// Whether nothing is placed (every object at its default).
  bool get isEmpty => grid == null && panels.isEmpty;

  @override
  List<Object?> get props => [name, grid, panels];
}

import 'package:equatable/equatable.dart';

import 'output_spec.dart';
import 'pixel_mask.dart';

/// Which radio panels a [Region] draws on.
sealed class RegionPanels extends Equatable {
  const RegionPanels();

  /// Every panel of the target.
  const factory RegionPanels.all() = AllPanels;

  /// No panel at all.
  const factory RegionPanels.none() = NoPanels;

  /// Only the panels with the given 1-based [indices]; an empty set behaves
  /// like [RegionPanels.none] (but is a distinct value).
  const factory RegionPanels.some(Set<int> indices) = SomePanels;

  /// Whether the 1-based panel [index] is drawn on.
  bool contains(int index);
}

/// Every radio panel.
final class AllPanels extends RegionPanels {
  const AllPanels();

  @override
  bool contains(int index) => true;

  @override
  List<Object?> get props => const [];

  @override
  String toString() => 'RegionPanels.all()';
}

/// No radio panel.
final class NoPanels extends RegionPanels {
  const NoPanels();

  @override
  bool contains(int index) => false;

  @override
  List<Object?> get props => const [];

  @override
  String toString() => 'RegionPanels.none()';
}

/// A chosen set of radio panels, by 1-based index.
final class SomePanels extends RegionPanels {
  /// 1-based panel indices.
  final Set<int> indices;

  const SomePanels(this.indices);

  @override
  bool contains(int index) => indices.contains(index);

  @override
  List<Object?> get props => [indices];

  @override
  String toString() => 'RegionPanels.some(${indices.toList()..sort()})';
}

/// An inclusive, 0-based range of icicle columns.
class ColumnRange extends Equatable {
  /// First column, 0-based.
  final int first;

  /// Last column, 0-based, inclusive.
  final int last;

  /// Throws an [ArgumentError] when [first] is negative or after [last].
  ColumnRange(this.first, this.last) {
    if (first < 0) throw ArgumentError.value(first, 'first', 'Must not be negative.');
    if (last < first) throw ArgumentError.value(last, 'last', 'Must not be before first ($first).');
  }

  /// Number of columns in the range.
  int get length => last - first + 1;

  /// Whether the 0-based [column] lies in the range.
  bool contains(int column) => column >= first && column <= last;

  @override
  List<Object?> get props => [first, last];

  @override
  String toString() => 'ColumnRange($first, $last)';
}

/// Which part of the output a clip draws on: the icicles grid (every column
/// or a [ColumnRange]) and/or a choice of radio panels.
///
/// The three classic regions are [Region.all], [Region.iciclesOnly] and
/// [Region.panelsOnly].
class Region extends Equatable {
  /// Whether the clip draws on the icicles grid.
  final bool icicles;

  /// The columns drawn on when [icicles]; `null` = every column.
  final ColumnRange? columns;

  /// The radio panels drawn on.
  final RegionPanels panels;

  /// A per-pixel mask over the icicle and radio panel pixels, intersected
  /// with [columns] and [panels]; `null` = every pixel.
  final PixelMask? pixels;

  const Region({this.icicles = true, this.columns, this.panels = const RegionPanels.all(), this.pixels});

  /// The icicles grid and every radio panel.
  const Region.all() : this();

  /// Only the icicles grid, every column.
  const Region.iciclesOnly() : this(panels: const RegionPanels.none());

  /// Only the radio panels, all of them.
  const Region.panelsOnly() : this(icicles: false);

  /// Whether the clip draws on the icicles grid (some column).
  bool get coversIcicles => icicles;

  /// Whether the clip draws on at least one radio panel (of a target that
  /// has them).
  bool get coversRadioPanels => switch (panels) {
        AllPanels() => true,
        NoPanels() => false,
        SomePanels(:final indices) => indices.isNotEmpty,
      };

  /// Whether this is one of [Region.all], [Region.iciclesOnly] and
  /// [Region.panelsOnly] (no columns, no pixel mask).
  bool get isClassic => columns == null && pixels == null && (panels is AllPanels || (icicles && panels is NoPanels));

  /// Whether a per-pixel mask is set.
  bool get hasPixelMask => pixels != null;

  /// Whether the clip draws nothing at all.
  bool get isEmpty => !coversIcicles && !coversRadioPanels;

  /// Whether the pixels of the 0-based column [x] are drawn.
  bool affectsPixel(int x) => icicles && (columns?.contains(x) ?? true);

  /// Whether the 1-based radio panel [index] is drawn.
  bool affectsPanel(int index) => panels.contains(index);

  /// Whether the icicle pixel at column [x], row [y] (index `x · yCount + y`
  /// where `yCount` is that of [pixels], if set) is drawn: the column and
  /// the pixel mask.
  bool affectsIciclePixel(int x, int y) =>
      affectsPixel(x) && (pixels == null || pixels!.contains(x * pixels!.yCount + y));

  /// Whether the LED [led] of the 1-based radio panel [index] is drawn: the
  /// panel and the pixel mask.
  bool affectsPanelPixel(int index, int led) =>
      affectsPanel(index) && (pixels == null || pixels!.containsPanelPixel(index, led));

  /// This region fitted to [target]: the column range is clamped to the
  /// grid (`null` once it covers every column; a range entirely outside the
  /// grid turns [icicles] off), panel indices outside
  /// `1..radioPanelsCount` are dropped (an emptied set becomes
  /// [RegionPanels.none], a complete one [RegionPanels.all]); the pixel
  /// mask is re-dimensioned with [PixelMask.fitTo] (a full one is dropped).
  Region normalized(OutputSpec target) {
    var icicles = this.icicles;
    var columns = this.columns;
    if (columns != null) {
      if (columns.first >= target.xCount) {
        icicles = false;
        columns = null;
      } else {
        final last = columns.last < target.xCount ? columns.last : target.xCount - 1;
        columns = columns.first == 0 && last == target.xCount - 1 ? null : ColumnRange(columns.first, last);
      }
    }
    final panels = switch (this.panels) {
      SomePanels(:final indices) => _normalizedPanels(indices, target.radioPanelsCount),
      final other => other,
    };
    var pixels = this.pixels?.fitTo(target);
    if (pixels != null && pixels.isFull) pixels = null;
    return Region(icicles: icicles, columns: columns, panels: panels, pixels: pixels);
  }

  static RegionPanels _normalizedPanels(Set<int> indices, int count) {
    final kept = {
      for (final index in indices)
        if (index >= 1 && index <= count) index,
    };
    if (kept.isEmpty) return const RegionPanels.none();
    if (kept.length == count) return const RegionPanels.all();
    return RegionPanels.some(kept);
  }

  /// A copy with the given fields replaced; [columns] and [pixels] are
  /// thunks so that they can be cleared (`() => null`).
  Region copyWith({
    bool? icicles,
    ColumnRange? Function()? columns,
    RegionPanels? panels,
    PixelMask? Function()? pixels,
  }) =>
      Region(
        icicles: icicles ?? this.icicles,
        columns: columns == null ? this.columns : columns(),
        panels: panels ?? this.panels,
        pixels: pixels == null ? this.pixels : pixels(),
      );

  @override
  List<Object?> get props => [icicles, columns, panels, pixels];

  @override
  String toString() => 'Region(icicles: $icicles, columns: $columns, panels: $panels, pixels: $pixels)';
}

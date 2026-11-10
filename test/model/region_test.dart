import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  group('Region', () {
    test('the classic regions cover what the old enum did', () {
      const all = Region.all();
      const icicles = Region.iciclesOnly();
      const panels = Region.panelsOnly();
      expect((all.coversIcicles, all.coversRadioPanels, all.isClassic, all.isEmpty), (true, true, true, false));
      expect((icicles.coversIcicles, icicles.coversRadioPanels, icicles.isClassic), (true, false, true));
      expect((panels.coversIcicles, panels.coversRadioPanels, panels.isClassic), (false, true, true));
      expect(all, const Region(icicles: true, panels: RegionPanels.all()));
      expect(const Region(), all);
    });

    test('column ranges and panel sets are not classic', () {
      expect(Region(columns: ColumnRange(0, 1)).isClassic, isFalse);
      expect(const Region(panels: RegionPanels.some({1})).isClassic, isFalse);
      expect(const Region(icicles: false, panels: RegionPanels.none()).isClassic, isFalse);
    });

    test('affectsPixel masks columns, affectsPanel masks panels', () {
      final region = Region(columns: ColumnRange(1, 2), panels: const RegionPanels.some({1, 3}));
      expect([0, 1, 2, 3].map(region.affectsPixel), [false, true, true, false]);
      expect([1, 2, 3].map(region.affectsPanel), [true, false, true]);
      expect(const Region.panelsOnly().affectsPixel(0), isFalse);
      expect(const Region.iciclesOnly().affectsPanel(1), isFalse);
      expect(Region(icicles: false, columns: ColumnRange(0, 0)).affectsPixel(0), isFalse);
    });

    test('isEmpty when nothing is drawn', () {
      expect(const Region(icicles: false, panels: RegionPanels.none()).isEmpty, isTrue);
      expect(const Region(icicles: false, panels: RegionPanels.some({})).isEmpty, isTrue);
      expect(const Region(icicles: false, panels: RegionPanels.some({2})).isEmpty, isFalse);
      expect(const Region.iciclesOnly().isEmpty, isFalse);
    });

    test('values compare by content, panel sets regardless of order', () {
      expect(const Region(panels: RegionPanels.some({1, 3})), const Region(panels: RegionPanels.some({3, 1})));
      expect(Region(columns: ColumnRange(0, 2)), Region(columns: ColumnRange(0, 2)));
      expect(Region(columns: ColumnRange(0, 2)), isNot(Region(columns: ColumnRange(0, 1))));
      expect(const RegionPanels.all(), isNot(const RegionPanels.none()));
      expect(const RegionPanels.some({}), isNot(const RegionPanels.none()));
    });

    test('ColumnRange rejects negative or reversed bounds', () {
      expect(() => ColumnRange(-1, 0), throwsArgumentError);
      expect(() => ColumnRange(2, 1), throwsArgumentError);
      expect(ColumnRange(2, 2).length, 1);
      expect(ColumnRange(1, 4).contains(4), isTrue);
      expect(ColumnRange(1, 4).contains(5), isFalse);
    });

    test('normalized clamps the column range to the grid and drops it when it covers everything', () {
      final target = testSpec(radioPanelsCount: 3); // 3 columns.
      expect(Region(columns: ColumnRange(1, 9)).normalized(target), Region(columns: ColumnRange(1, 2)));
      expect(Region(columns: ColumnRange(0, 9)).normalized(target), const Region.all());
      expect(Region(columns: ColumnRange(0, 2)).normalized(target), const Region.all());
      expect(Region(columns: ColumnRange(5, 9)).normalized(target), const Region.panelsOnly());
      expect(Region(columns: ColumnRange(1, 1)).normalized(target), Region(columns: ColumnRange(1, 1)));
    });

    test('normalized drops panel indices the target does not have', () {
      final target = testSpec(radioPanelsCount: 3);
      expect(const Region(panels: RegionPanels.some({1, 3, 7})).normalized(target),
          const Region(panels: RegionPanels.some({1, 3})));
      expect(const Region(panels: RegionPanels.some({5, 7})).normalized(target),
          const Region(panels: RegionPanels.none()));
      expect(const Region(panels: RegionPanels.some({1, 2, 3})).normalized(target), const Region.all());
      expect(const Region(panels: RegionPanels.some({1})).normalized(testSpec()),
          const Region(panels: RegionPanels.none()));
      expect(const Region.all().normalized(testSpec()), const Region.all());
    });

    test('copyWith can clear the column range', () {
      final ranged = Region(columns: ColumnRange(0, 1));
      expect(ranged.copyWith(columns: () => null), const Region.all());
      expect(ranged.copyWith(icicles: false).columns, ColumnRange(0, 1));
      expect(ranged.copyWith(panels: const RegionPanels.none()).panels, const RegionPanels.none());
    });
  });
}

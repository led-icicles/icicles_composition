import 'dart:typed_data';

import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  final target = testSpec(radioPanelsCount: 2, radioPanelPixelCount: 3); // 6 icicle + 6 panel pixels

  group('PixelMask', () {
    test('full and empty masks', () {
      final full = PixelMask.full(target);
      expect((full.length, full.coveredCount, full.isFull, full.isEmpty), (12, 12, true, false));
      expect(full.bits, [0xFF, 0x0F]);
      final empty = PixelMask.empty(target);
      expect((empty.coveredCount, empty.isFull, empty.isEmpty), (0, false, true));
      expect(full.fits(target), isTrue);
      expect(full.fits(testSpec()), isFalse);
      expect(full, PixelMask.full(target));
      expect(full, isNot(empty));
    });

    test('contains, withPixel and withPanelPixel address icicle then panel pixels', () {
      var mask = PixelMask.empty(target).withPixel(3, true).withPanelPixel(2, 1, true);
      expect(mask.contains(3), isTrue);
      expect(mask.contains(2), isFalse);
      expect(mask.containsPanelPixel(2, 1), isTrue);
      expect(mask.containsPanelPixel(1, 1), isFalse);
      expect(mask.containsIndex(6 + 3 + 1), isTrue);
      expect(mask.coveredCount, 2);
      mask = mask.withPixel(3, false);
      expect(mask.contains(3), isFalse);
      // Out-of-range indices are ignored and never set.
      expect(mask.withPixel(6, true), mask);
      expect(mask.withPixel(-1, true), mask);
      expect(mask.withPanelPixel(3, 0, true), mask);
      expect(mask.withPanelPixel(1, 3, true), mask);
      expect(mask.contains(99), isFalse);
      expect(mask.containsPanelPixel(0, 0), isFalse);
    });

    test('withPixels sets several at once, inverted flips within the length', () {
      final mask = PixelMask.empty(target).withPixels(icicles: [0, 5, 7], panelPixels: [(1, 0), (2, 2)], value: true);
      expect(mask.coveredCount, 4);
      final inverted = mask.inverted();
      expect(inverted.coveredCount, 8);
      expect(inverted.contains(0), isFalse);
      expect(inverted.contains(1), isTrue);
      expect(inverted.inverted(), mask);
      expect(PixelMask.empty(target).inverted(), PixelMask.full(target));
    });

    test('the constructor checks the byte count and clears padding bits', () {
      expect(() => PixelMask(xCount: 3, yCount: 2, bits: Uint8List(2)), throwsArgumentError);
      expect(() => PixelMask(xCount: -1, yCount: 2, bits: Uint8List(0)), throwsArgumentError);
      final mask = PixelMask(xCount: 3, yCount: 2, bits: Uint8List.fromList([0xFF]));
      expect(mask.bits, [0x3F]);
      expect(mask.isFull, isTrue);
      expect(PixelMask(xCount: 0, yCount: 0, bits: Uint8List(0)).isFull, isTrue);
    });

    test('fitTo keeps overlapping pixels by position and includes new ones', () {
      final mask = PixelMask.empty(target).withPixel(2 * 2 + 1, true).withPanelPixel(1, 2, true); // x2,y1; p1 led2
      final bigger = testSpec(radioPanelsCount: 3, radioPanelPixelCount: 4).copyWith(xCount: 4, yCount: 3);
      final fitted = mask.fitTo(bigger);
      expect(fitted.fits(bigger), isTrue);
      expect(fitted.contains(2 * 3 + 1), isTrue);
      expect(fitted.contains(0), isFalse);
      expect(fitted.contains(2 * 3 + 2), isTrue, reason: 'new row');
      expect(fitted.contains(3 * 3), isTrue, reason: 'new column');
      expect(fitted.containsPanelPixel(1, 2), isTrue);
      expect(fitted.containsPanelPixel(1, 0), isFalse);
      expect(fitted.containsPanelPixel(1, 3), isTrue, reason: 'new LED');
      expect(fitted.containsPanelPixel(3, 0), isTrue, reason: 'new panel');
      expect(identical(mask.fitTo(target), mask), isTrue);

      final smaller = mask.fitTo(testSpec());
      expect((smaller.length, smaller.coveredCount), (6, 1));
      expect(smaller.contains(5), isTrue);
    });
  });

  group('Region with pixels', () {
    test('intersects the mask with columns and panels', () {
      final mask = PixelMask.full(target).withPixel(0, false).withPanelPixel(2, 0, false);
      final region = Region(columns: ColumnRange(0, 1), panels: const RegionPanels.some({2}), pixels: mask);
      expect(region.isClassic, isFalse);
      expect(region.hasPixelMask, isTrue);
      expect(region.affectsIciclePixel(0, 0), isFalse);
      expect(region.affectsIciclePixel(0, 1), isTrue);
      expect(region.affectsIciclePixel(2, 0), isFalse, reason: 'outside the columns');
      expect(region.affectsPanelPixel(2, 0), isFalse);
      expect(region.affectsPanelPixel(2, 1), isTrue);
      expect(region.affectsPanelPixel(1, 1), isFalse, reason: 'outside the panels');
      expect(Region(pixels: mask).isClassic, isFalse);
      expect(region.copyWith(pixels: () => null),
          Region(columns: ColumnRange(0, 1), panels: const RegionPanels.some({2})));
    });

    test('normalized fits the mask to the target and drops a full one', () {
      final mask = PixelMask.full(testSpec()).withPixel(1, false);
      final region = Region(pixels: mask);
      final fitted = region.normalized(target);
      expect(fitted.pixels!.fits(target), isTrue);
      expect(fitted.pixels!.contains(1), isFalse);
      expect(fitted.pixels!.coveredCount, 11);
      expect(Region(pixels: PixelMask.full(testSpec())).normalized(target), const Region.all());
    });
  });
}

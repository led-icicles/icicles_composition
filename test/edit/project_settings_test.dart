import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  group('setTarget', () {
    test('keeps every clip and fits the regions (pixel masks included) to the new layout', () {
      final mask = PixelMask.empty(testSpec()).withPixel(0, true).withPixel(5, true);
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          testClip('a', sourceOut: s(1), region: Region(columns: ColumnRange(1, 2), pixels: mask)),
          testClip('g',
              source: GeneratorRef(generatorId: 'g', generatorVersion: 1, seed: 1, length: s(1)),
              start: s(2),
              sourceOut: s(1),
              region: const Region(panels: RegionPanels.some({1, 2}))),
        ]),
      ]);
      final target = OutputSpec(xCount: 2, yCount: 2, radioPanelsCount: 1);
      final changed = composition.setTarget(target);
      expect(changed.target, target);
      expect(changed.placedClips.length, 2, reason: 'clips of another layout stay (reported by the app)');
      final region = changed.findClip('a')!.clip.region;
      expect(region.columns, ColumnRange(1, 1));
      expect(region.pixels!.fits(target), isTrue);
      expect(region.pixels!.contains(0), isTrue);
      expect(changed.findClip('g')!.clip.region.panels, const RegionPanels.all());
      expect(identical(composition.setTarget(composition.target), composition), isTrue, reason: 'no-op');
    });
  });

  group('setFramerate and rename', () {
    test('change the fields; unsupported values are refused', () {
      final composition = testComposition();
      expect(composition.setFramerate(Framerate.fps45).framerate, Framerate.fps45);
      expect(identical(composition.setFramerate(Framerate.fps30), composition), isTrue);
      expect(
        () => composition.setFramerate(Framerate.fps60),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidValue)),
      );
      expect(composition.rename('Show').name, 'Show');
      expect(identical(composition.rename('test'), composition), isTrue);
      expect(
        () => composition.rename('a\u0000b'),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidValue)),
      );
    });
  });
}

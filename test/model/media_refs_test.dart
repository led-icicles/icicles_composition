import 'dart:typed_data';

import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  group('ImageRef', () {
    test('compares by paths and options, exposes path and isSequence', () {
      final single = ImageRef.single(path: 'a.png', contentHash: 'h');
      expect(single, ImageRef(paths: ['a.png'], contentHash: 'h'));
      expect(single.path, 'a.png');
      expect(single.isSequence, isFalse);
      expect(single.isIndexed, isTrue);
      expect(single, isNot(single.copyWith(fit: ImageFit.contain)));
      final sequence = ImageRef(paths: ['1.png', '2.png'], contentHash: 'h', frameDuration: ms(40));
      expect(sequence.isSequence, isTrue);
      expect(sequence.copyWith(clearFrameDuration: true).frameDuration, isNull);
      expect(sequence.label, '1.png');
    });

    test('refuses empty paths and non-positive frame durations', () {
      expect(() => ImageRef(paths: const [], contentHash: 'h'), throwsArgumentError);
      expect(() => ImageRef(paths: const ['a.png', ''], contentHash: 'h'), throwsArgumentError);
      expect(() => ImageRef.single(path: 'a.png', contentHash: 'h', frameDuration: Duration.zero), throwsArgumentError);
    });
  });

  group('DrawingRef', () {
    test('a blank drawing is one black frame of the layout', () {
      final drawing = DrawingRef.blank(id: 'd1', xCount: 3, yCount: 2, radioPanelsCount: 2, radioPanelPixelCount: 4);
      expect(drawing.pixelCount, 6 + 8);
      expect(drawing.frames.single.pixelCount, 14);
      expect(drawing.duration, DrawingRef.defaultFrameDuration);
      expect(drawing.panelPixelIndex(2, 1), 6 + 4 + 1);
      expect(drawing.fits(OutputSpec(xCount: 3, yCount: 2, radioPanelsCount: 2, radioPanelPixelCount: 4)), isTrue);
      expect(drawing.fits(testSpec()), isFalse);
      expect(
          drawing.header.hasSameLayout(
              AnimationHeader(name: '', xCount: 3, yCount: 2, radioPanelsCount: 2, radioPanelPixelCount: 4)),
          isTrue);
    });

    test('toViews puts the icicle pixels column-major and the panel pixels per panel', () {
      final drawing = DrawingRef.blank(id: 'd', xCount: 2, yCount: 2, radioPanelsCount: 1, radioPanelPixelCount: 2);
      final painted = drawing.copyWith(frames: [
        drawing.frames.single.withPixels({
          3: const Color.fromRGB(255, 0, 0), // x 1, y 1
          drawing.panelPixelIndex(1, 1): const Color.fromRGB(0, 0, 255),
        }).copyWith(duration: ms(250)),
        DrawingFrame.blank(duration: ms(750), pixelCount: drawing.pixelCount),
      ]);
      final views = painted.toViews();
      expect(views, hasLength(2));
      expect(views.first.frame.duration, ms(250));
      expect(views.first.frame.pixels[3], const Color.fromRGB(255, 0, 0));
      expect(views.first.frame.pixels[0], const Color.fromRGB(0, 0, 0));
      expect(views.first.radioPanels.single.index, 1);
      expect(views.first.radioPanels.single.colors, [const Color.fromRGB(0, 0, 0), const Color.fromRGB(0, 0, 255)]);
      expect(painted.duration, s(1));
      expect(AnimationIndex(views).duration, s(1));
      expect(painted, isNot(drawing));
      expect(painted.copyWith(), painted);
    });

    test('refuses frames of another size, no frames and bad layouts', () {
      expect(
        () => DrawingRef(
          id: 'd',
          xCount: 2,
          yCount: 2,
          radioPanelsCount: 0,
          radioPanelPixelCount: 0,
          frames: [DrawingFrame.blank(duration: ms(10), pixelCount: 3)],
        ),
        throwsArgumentError,
      );
      expect(
        () => DrawingRef(id: 'd', xCount: 2, yCount: 2, radioPanelsCount: 0, radioPanelPixelCount: 0, frames: const []),
        throwsArgumentError,
      );
      expect(() => DrawingRef.blank(id: '', xCount: 1, yCount: 1, radioPanelsCount: 0, radioPanelPixelCount: 0),
          throwsArgumentError);
      expect(() => DrawingFrame(duration: Duration.zero, pixels: Uint8List(3)), throwsArgumentError);
      expect(() => DrawingFrame(duration: ms(1), pixels: Uint8List(4)), throwsArgumentError);
    });
  });

  group('CompositionRef', () {
    test('compares by path and hash', () {
      final a = CompositionRef(path: 'intro.icproj', contentHash: 'h');
      expect(a, CompositionRef(path: 'intro.icproj', contentHash: 'h'));
      expect(a, isNot(a.copyWith(contentHash: 'other')));
      expect(a.label, 'intro.icproj');
      expect(a.isIndexed, isTrue);
      expect(() => CompositionRef(path: '', contentHash: 'h'), throwsArgumentError);
    });
  });

  group('DrawingPixelsCodec', () {
    test('round-trips runs, long runs and a tail', () {
      final rgb = Uint8List(300 * 3);
      for (var i = 0; i < 300; i++) {
        final color = i < 260 ? 7 : (i.isEven ? 1 : 2);
        rgb[i * 3] = color;
        rgb[i * 3 + 1] = 0;
        rgb[i * 3 + 2] = 200;
      }
      final text = DrawingPixelsCodec.encode(rgb);
      expect(DrawingPixelsCodec.decode(text, pixelCount: 300), rgb);
      // 255 + 5 of the first color, then 40 alternating pixels = 42 runs.
      expect(text.length, lessThan(300 * 3));
      expect(DrawingPixelsCodec.encode(Uint8List(0)), '');
      expect(DrawingPixelsCodec.decode('', pixelCount: 0), isEmpty);
    });

    test('rejects a pixel count mismatch and bad input', () {
      final text = DrawingPixelsCodec.encode(Uint8List(6));
      expect(() => DrawingPixelsCodec.decode(text, pixelCount: 3), throwsFormatException);
      expect(() => DrawingPixelsCodec.decode(text, pixelCount: 1), throwsFormatException);
      expect(() => DrawingPixelsCodec.decode('***', pixelCount: 1), throwsFormatException);
      expect(() => DrawingPixelsCodec.decode('AAAA', pixelCount: 1), throwsFormatException); // a run of 0
    });
  });
}

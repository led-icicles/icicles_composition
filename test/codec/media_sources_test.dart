import 'dart:convert';
import 'dart:typed_data';

import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Map<String, Object?> sourceOf(Map<String, Object?> json, int clipIndex) {
  final track = (json['tracks']! as List<Object?>).first! as Map<String, Object?>;
  final clip = (track['clips']! as List<Object?>)[clipIndex]! as Map<String, Object?>;
  return clip['source']! as Map<String, Object?>;
}

void main() {
  final drawing = DrawingRef.blank(
    id: 'd1',
    name: 'Logo',
    xCount: testXCount,
    yCount: testYCount,
    radioPanelsCount: 1,
    radioPanelPixelCount: 2,
    frameDuration: ms(500),
  );
  final painted = drawing.copyWith(frames: [
    drawing.frames.single.withPixels({0: const Color.fromRGB(255, 10, 0), 7: const Color.fromRGB(0, 0, 9)}),
    DrawingFrame.blank(duration: ms(250), pixelCount: drawing.pixelCount),
  ]);
  final image = ImageRef.single(path: 'img/a.png', contentHash: 'sha256:a', fit: ImageFit.contain);
  final sequence = ImageRef(
    paths: ['seq/1.png', 'seq/2.png'],
    contentHash: 'sha256:s',
    panels: ImagePanelMode.off,
    frameDuration: ms(40),
  );
  final nested = CompositionRef(path: 'intro.icproj', contentHash: 'sha256:n');

  Composition composition() => Composition(
        name: 'Media',
        target: testSpec(radioPanelsCount: 1, radioPanelPixelCount: 2),
        tracks: [
          VisualTrack(id: 't', clips: [
            testClip('img', source: image, sourceOut: s(10)),
            testClip('seq', source: sequence, start: s(10), sourceOut: ms(80), loopDuration: s(2)),
            testClip('drw', source: painted, start: s(12), sourceOut: ms(750), reverse: true),
            testClip('nest', source: nested, start: s(13), sourceOut: s(5), speed: 2),
          ]),
        ],
      );

  group('media sources', () {
    test('are written as version 2 objects with a type', () {
      final json = IcprojCodec.toJson(composition());
      expect(json['version'], 2);
      expect(sourceOf(json, 0), {
        'type': 'image',
        'path': 'img/a.png',
        'contentHash': 'sha256:a',
        'fit': 'contain',
        'panels': 'average',
      });
      expect(sourceOf(json, 1), {
        'type': 'image',
        'paths': ['seq/1.png', 'seq/2.png'],
        'contentHash': 'sha256:s',
        'fit': 'cover',
        'panels': 'off',
        'frameDurationUs': 40000,
      });
      final drawingJson = sourceOf(json, 2);
      expect(drawingJson['type'], 'drawing');
      expect(drawingJson['id'], 'd1');
      expect(drawingJson['name'], 'Logo');
      expect(drawingJson['x'], testXCount);
      expect(drawingJson['y'], testYCount);
      expect(drawingJson['panels'], 1);
      expect(drawingJson['panelPixels'], 2);
      final frames = drawingJson['frames']! as List<Object?>;
      expect(frames, hasLength(2));
      expect((frames.first! as Map<String, Object?>)['durationUs'], 500000);
      expect((frames.first! as Map<String, Object?>)['pixels'], DrawingPixelsCodec.encode(painted.frames.first.pixels));
      expect(sourceOf(json, 3), {'type': 'composition', 'path': 'intro.icproj', 'contentHash': 'sha256:n'});
    });

    test('round-trip through the document keeps every source', () {
      final original = composition();
      final result = IcprojCodec.decode(IcprojCodec.encode(original));
      expect(result.problems, isEmpty);
      expect(result.composition, original);
      final sources = result.composition.sources.toList();
      expect(sources, containsAll([image, sequence, painted, nested]));
    });

    test('sourceToJson / sourceFromJson round-trip a source outside a document', () {
      for (final source in [image, sequence, painted, nested, ref('a')]) {
        expect(IcprojCodec.sourceFromJson(IcprojCodec.sourceToJson(source)), source);
      }
      expect(() => IcprojCodec.sourceFromJson({'type': 'image'}), throwsA(isA<IcprojException>()));
      expect(() => IcprojCodec.sourceFromJson(null), throwsA(isA<IcprojException>()));
    });

    test('salvages unknown image options and a bad frame duration', () {
      final json = IcprojCodec.toJson(composition());
      final source = sourceOf(json, 0)
        ..['fit'] = 'zoom'
        ..['panels'] = 7
        ..['frameDurationUs'] = -5;
      final result = IcprojCodec.decode(jsonEncode(json));
      expect(result.problems.map((problem) => problem.kind), everyElement(IcprojProblemKind.defaultedValue));
      expect(result.problems, hasLength(3));
      final decoded = result.composition.findClip('img')!.clip.source as ImageRef;
      expect(decoded.fit, ImageFit.cover);
      expect(decoded.panels, ImagePanelMode.average);
      expect(decoded.frameDuration, isNull);
      expect(source['path'], 'img/a.png');
    });

    test('drops an unreadable drawing frame, and the clip without any readable frame', () {
      final json = IcprojCodec.toJson(composition());
      final frames = sourceOf(json, 2)['frames']! as List<Object?>;
      (frames[1]! as Map<String, Object?>)['pixels'] = 'AAAA'; // a run of 0 pixels
      var result = IcprojCodec.decode(jsonEncode(json));
      expect(result.problems.single.kind, IcprojProblemKind.droppedFrame);
      final decoded = result.composition.findClip('drw')!.clip.source as DrawingRef;
      expect(decoded.frames, hasLength(1));
      expect(decoded.frames.single, painted.frames.first);

      (frames[0]! as Map<String, Object?>)['pixels'] = 42;
      result = IcprojCodec.decode(jsonEncode(json));
      expect(result.problems.map((problem) => problem.kind),
          containsAll([IcprojProblemKind.droppedFrame, IcprojProblemKind.droppedClip]));
      expect(result.composition.findClip('drw'), isNull);
      expect(result.composition.findClip('nest'), isNotNull);
    });

    test('a frame shorter than 1 ms is clamped; a wrong pixel count drops the frame', () {
      final json = IcprojCodec.toJson(composition());
      final frames = sourceOf(json, 2)['frames']! as List<Object?>;
      (frames[1]! as Map<String, Object?>)['durationUs'] = 10;
      (frames[0]! as Map<String, Object?>)['pixels'] = DrawingPixelsCodec.encode(Uint8ListOf(3));
      final result = IcprojCodec.decode(jsonEncode(json));
      expect(result.problems.map((problem) => problem.kind),
          containsAll([IcprojProblemKind.clampedValue, IcprojProblemKind.droppedFrame]));
      final decoded = result.composition.findClip('drw')!.clip.source as DrawingRef;
      expect(decoded.frames.single.duration, DrawingFrame.minDuration);
    });

    test('an image without any path and an unknown type drop the clip', () {
      final json = IcprojCodec.toJson(composition());
      sourceOf(json, 1)['paths'] = <Object?>[];
      sourceOf(json, 3)['type'] = 'video';
      final result = IcprojCodec.decode(jsonEncode(json));
      expect(result.problems.where((problem) => problem.kind == IcprojProblemKind.droppedClip), hasLength(2));
      expect(result.composition.placedClips.map((placed) => placed.clip.id), ['img', 'drw']);
    });
  });
}

// A tiny byte list helper (keeps the test file free of a typed_data import).
// ignore: non_constant_identifier_names
Uint8List Uint8ListOf(int pixels) => Uint8List(pixels * 3);

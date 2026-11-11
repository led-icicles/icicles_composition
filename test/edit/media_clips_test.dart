import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  final target = testSpec(radioPanelsCount: 1, radioPanelPixelCount: 2);
  final image = ImageRef.single(path: 'a.png', contentHash: 'h');
  SourceInfo imageInfo({Duration duration = const Duration(seconds: 10), OutputSpec? layout}) =>
      SourceInfo(header: (layout ?? target).toHeader(name: ''), duration: duration);
  final drawing = DrawingRef.blank(
    id: 'd',
    xCount: testXCount,
    yCount: testYCount,
    radioPanelsCount: 1,
    radioPanelPixelCount: 2,
    frameDuration: s(1),
  );

  Composition empty() => Composition(name: 'c', target: target, tracks: [VisualTrack(id: 't')]);

  group('addClip with media sources', () {
    test('an image clip needs its SourceInfo and the target layout', () {
      final clip = testClip('i', source: image, sourceOut: s(10));
      expect(
        () => empty().addClip('t', clip),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidValue)),
      );
      expect(
        () => empty().addClip('t', clip, imageInfo(layout: testSpec())),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.layoutMismatch)),
      );
      final added = empty().addClip('t', testClip('i', source: image, sourceOut: s(20)), imageInfo());
      // The trim is clamped to the source length, like a file clip.
      expect(added.findClip('i')!.clip.sourceOut, s(10));
      expect(added.findClip('i')!.clip.isParametric, isFalse);
    });

    test('a drawing clip uses SourceInfo.ofDrawing and plays like a file (loop, speed)', () {
      final clip = testClip('d', source: drawing, sourceOut: s(1), speed: 2, loopDuration: s(4));
      final added = empty().addClip('t', clip, SourceInfo.ofDrawing(drawing));
      expect(added.findClip('d')!.clip.duration, s(4));
      expect(SourceInfo.ofDrawing(drawing).duration, s(1));
    });

    test('a nested composition clip is an indexed clip too', () {
      final nested = CompositionRef(path: 'intro.icproj', contentHash: 'h');
      final added = empty().addClip('t', testClip('n', source: nested, sourceOut: s(3)), imageInfo(duration: s(3)));
      expect(added.sources, {nested});
    });
  });

  group('setClipSource', () {
    final base = empty().addClip('t', testClip('d', source: drawing, sourceOut: s(1)), SourceInfo.ofDrawing(drawing));

    test('replaces a drawing with its edited version (one more frame) keeping the trim', () {
      final longer = drawing.copyWith(frames: [
        ...drawing.frames,
        DrawingFrame.blank(duration: ms(500), pixelCount: drawing.pixelCount),
      ]);
      final edited = base.setClipSource('d', longer, SourceInfo.ofDrawing(longer));
      final clip = edited.findClip('d')!.clip;
      expect(clip.source, longer);
      expect(clip.sourceIn, Duration.zero);
      expect(clip.sourceOut, s(1));
      expect(edited.sources, {longer});
    });

    test('clamps the trim to a shorter source and restarts a trim beyond its end', () {
      final trimmed = base.dragClipEdge('d', ClipEdge.start, ms(600), sourceDuration: s(1));
      expect(trimmed.findClip('d')!.clip.sourceIn, ms(600));
      final shorter = drawing.copyWith(frames: [drawing.frames.single.copyWith(duration: ms(800))]);
      var edited = trimmed.setClipSource('d', shorter, SourceInfo.ofDrawing(shorter));
      expect(edited.findClip('d')!.clip.sourceIn, ms(600));
      expect(edited.findClip('d')!.clip.sourceOut, ms(800));

      final tiny = drawing.copyWith(frames: [drawing.frames.single.copyWith(duration: ms(300))]);
      edited = trimmed.setClipSource('d', tiny, SourceInfo.ofDrawing(tiny));
      expect(edited.findClip('d')!.clip.sourceIn, Duration.zero);
      expect(edited.findClip('d')!.clip.sourceOut, ms(300));
    });

    test('stops the clip at the next clip when the new source is longer', () {
      final two =
          base.addClip('t', testClip('i', source: image, start: s(1), sourceOut: s(2)), imageInfo(duration: s(2)));
      final longer = drawing.copyWith(frames: [drawing.frames.single.copyWith(duration: s(3))]);
      final edited = two.setClipSource('d', longer, SourceInfo.ofDrawing(longer));
      expect(edited.findClip('d')!.clip.end, lessThanOrEqualTo(s(1)));
    });

    test('needs the info for an indexed source and refuses a kind change', () {
      expect(
        () => base.setClipSource('d', image),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidValue)),
      );
      final generator = GeneratorRef(generatorId: 'g', generatorVersion: 1, seed: 1, length: s(2));
      expect(
        () => base.setClipSource('d', generator),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidValue)),
      );
      expect(
        () => base.setClipSource('d', image, imageInfo(layout: testSpec())),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.layoutMismatch)),
      );
      // An image may replace a drawing: both are indexed sources.
      expect(base.setClipSource('d', image, imageInfo()).findClip('d')!.clip.source, image);
    });

    test('refuses on a locked track', () {
      final locked = base.updateTrack('t', locked: true);
      expect(
        () => locked.setClipSource('d', drawing, SourceInfo.ofDrawing(drawing)),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.trackLocked)),
      );
    });
  });

  group('compositor', () {
    test('draws a drawing from its index and reports a missing image as offline', () {
      final painted = drawing.copyWith(frames: [
        drawing.frames.single.withPixels(
            {1: const Color.fromRGB(0, 255, 0), drawing.panelPixelIndex(1, 0): const Color.fromRGB(9, 9, 9)}),
      ]);
      final composition = empty()
          .addClip('t', testClip('d', source: painted, sourceOut: s(1)), SourceInfo.ofDrawing(painted))
          .addClip('t', testClip('i', source: image, start: s(1), sourceOut: s(2)), imageInfo(duration: s(2)));
      final sources = {painted: AnimationIndex(painted.toViews())};
      final view = Compositor.renderAt(composition, sources, ms(500));
      expect(view.frame.pixels[1], const Color.fromRGB(0, 255, 0));
      expect(view.radioPanels.single.colors.first, const Color.fromRGB(9, 9, 9));
      final offline = Compositor.offlineClips(composition, sources);
      expect(offline.single.clipId, 'i');
      expect(offline.single.reason, OfflineReason.missing);
    });
  });
}

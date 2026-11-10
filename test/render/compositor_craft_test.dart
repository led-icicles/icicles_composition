import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Map<SourceRef, AnimationIndex> indexes(Map<String, Animation> animations) =>
    {for (final MapEntry(:key, :value) in animations.entries) ref(key): value.toIndex()};

Color pixelAt(Composition composition, Map<SourceRef, AnimationIndex> sources, Duration time) =>
    firstPixel(Compositor.renderAt(composition, sources, time));

void main() {
  final red = solidAnimation([(Colors.red, s(4))]);
  final green = solidAnimation([(Colors.green, s(4))]);
  final sources = indexes({'red': red, 'green': green});
  // Frame k of the ramp has red = k and lasts 10 ms: 100 frames = 1 s.
  final rampSources = indexes({'ramp': rampAnimation(100)});

  group('solo', () {
    test('while any track is solo only the solo tracks render and count as offline', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 'low', clips: [testClip('a', source: ref('red'), sourceOut: s(2))]),
        VisualTrack(id: 'high', clips: [testClip('b', source: ref('green'), sourceOut: s(2))]),
        VisualTrack(id: 'top', clips: [testClip('c', source: ref('missing'), sourceOut: s(2))]),
      ]);
      expect(pixelAt(composition, sources, ms(100)), Colors.green);
      expect(Compositor.offlineClips(composition, sources).single.clipId, 'c');
      final soloLow = composition.updateTrack('low', solo: true);
      expect(pixelAt(soloLow, sources, ms(100)), Colors.red);
      expect(Compositor.offlineClips(soloLow, sources), isEmpty);
      final soloBoth = soloLow.updateTrack('high', solo: true);
      expect(pixelAt(soloBoth, sources, ms(100)), Colors.green);
      // A muted solo track stays silent.
      expect(pixelAt(soloBoth.updateTrack('high', muted: true), sources, ms(100)), Colors.red);
    });
  });

  group('reverse and ping-pong', () {
    test('a reversed clip shows the last source frame first', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          testClip('a', source: ref('ramp'), sourceIn: ms(200), sourceOut: ms(600), reverse: true),
        ]),
      ]);
      expect(pixelAt(composition, rampSources, Duration.zero).red, 59);
      expect(pixelAt(composition, rampSources, ms(100)).red, 49);
      expect(pixelAt(composition, rampSources, ms(399)).red, 20);
    });

    test('a ping-pong loop runs forward then backward', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          testClip('a', source: ref('ramp'), sourceIn: ms(200), sourceOut: ms(500), loopDuration: s(2), pingPong: true),
        ]),
      ]);
      expect(pixelAt(composition, rampSources, ms(100)).red, 30);
      expect(pixelAt(composition, rampSources, ms(300)).red, 49);
      expect(pixelAt(composition, rampSources, ms(400)).red, 39);
      expect(pixelAt(composition, rampSources, ms(599)).red, 20);
      expect(pixelAt(composition, rampSources, ms(600)).red, 20);
      expect(pixelAt(composition, rampSources, ms(700)).red, 30);
      final plain = composition.setClipPingPong('a', false);
      expect(pixelAt(plain, rampSources, ms(400)).red, 30);
    });
  });

  group('render range', () {
    test('exports exactly the grid frames covering the loop range', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [testClip('a', source: ref('ramp'), sourceOut: s(1))]),
      ]);
      final full = Compositor.render(composition, rampSources).animation;
      expect(full.frames.where((frame) => frame.duration > Duration.zero).length, 30);
      final range = LoopRange(start: ms(250), end: ms(500));
      final part = Compositor.render(composition, rampSources, range: range).animation;
      final first = frameIndexAt(Framerate.fps30, ms(250));
      final last = frameIndexAt(Framerate.fps30, us(499999));
      final expectedFrames = last - first + 1;
      final index = part.toIndex();
      expect(frameCountFor(Framerate.fps30, index.duration), expectedFrames);
      // The first exported frame is the preview frame containing the in point.
      final preview = Compositor.renderAt(composition, rampSources, Framerate.fps30.frameStart(first));
      expect(firstPixel(index.viewAt(Duration.zero)), firstPixel(preview));
      expect(firstPixel(index.viewAt(Duration.zero)).red, 23); // frame 7 starts at 233.3 ms
    });

    test('a range beyond the clips renders black frames rather than failing', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [testClip('a', source: ref('red'), sourceOut: ms(100))]),
      ]);
      final part = Compositor.render(composition, sources, range: LoopRange(start: s(2), end: s(3))).animation;
      expect(firstPixel(part.toIndex().viewAt(ms(10))), Colors.black);
    });
  });
}

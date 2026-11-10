import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  for (final framerate in [Framerate.fps30, Framerate.fps45, Framerate.fps24, Framerate.fps60]) {
    test('frameIndexAt inverts frameStart at ${framerate.framesPerSecond} fps', () {
      for (var i = 0; i < 3000; i++) {
        final start = framerate.frameStart(i);
        expect(frameIndexAt(framerate, start), i);
        expect(frameIndexAt(framerate, framerate.frameStart(i + 1) - us(1)), i);
      }
    });
  }

  test('frameIndexAt handles long timelines', () {
    expect(frameIndexAt(Framerate.fps45, const Duration(minutes: 3)), 8100);
    expect(frameIndexAt(Framerate.fps30, const Duration(hours: 2)), 216000);
  });

  test('frameIndexAt rejects negative times', () {
    expect(() => frameIndexAt(Framerate.fps30, us(-1)), throwsRangeError);
  });

  test('frameCountFor covers the duration', () {
    expect(frameCountFor(Framerate.fps30, Duration.zero), 0);
    expect(frameCountFor(Framerate.fps30, us(1)), 1);
    expect(frameCountFor(Framerate.fps30, s(1)), 30);
    expect(frameCountFor(Framerate.fps30, s(1) + us(1)), 31);
    expect(frameCountFor(Framerate.fps45, const Duration(minutes: 3)), 8100);
  });
}

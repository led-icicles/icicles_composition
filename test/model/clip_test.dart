import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  group('duration', () {
    test('plays the trimmed range once at the speed', () {
      final clip = testClip('c', sourceIn: ms(200), sourceOut: ms(1200), speed: 2);
      expect(clip.duration, ms(500));
      expect(clip.end, ms(500));
    });

    test('rounds the stretched length to the nearest microsecond', () {
      final clip = testClip('c', sourceOut: ms(1000), speed: 3);
      expect(clip.duration, closeToDuration(us(333333)));
    });

    test('is the loop duration for a looping clip', () {
      final clip = testClip('c', start: s(1), sourceOut: ms(300), loopDuration: s(2));
      expect(clip.duration, s(2));
      expect(clip.passDuration, ms(300));
      expect(clip.end, s(3));
    });
  });

  group('sourceTimeAt', () {
    test('maps timeline time through the trim and speed', () {
      final clip = testClip('c', start: s(1), sourceIn: ms(100), sourceOut: ms(900), speed: 2);
      expect(clip.sourceTimeAt(s(1)), ms(100));
      expect(clip.sourceTimeAt(ms(1100)), ms(300));
    });

    test('rounds down and never reaches sourceOut (range 1 s, speed 0.1, 10 s)', () {
      final clip = testClip('c', sourceOut: s(1), speed: 0.1);
      expect(clip.duration, s(10));
      final last = clip.end - us(1);
      // 9 999 999 µs × 0.1 = 999 999.9 µs: rounding would give sourceOut.
      expect(clip.sourceTimeAt(last), us(999999));
      expect(clip.sourceTimeAt(clip.end), us(999999), reason: 'clamped to sourceOut − 1 µs');
    });

    test('wraps a looping clip into the trimmed range', () {
      final clip = testClip('c', sourceIn: ms(100), sourceOut: ms(400), loopDuration: s(2));
      expect(clip.sourceTimeAt(ms(250)), ms(350));
      expect(clip.sourceTimeAt(ms(300)), ms(100));
      expect(clip.sourceTimeAt(ms(1950)), ms(250));
    });

    test('clamps times before the clip to sourceIn', () {
      final clip = testClip('c', start: s(1), sourceIn: ms(100), sourceOut: ms(400));
      expect(clip.sourceTimeAt(Duration.zero), ms(100));
    });
  });

  group('extendedSourceTimeAt', () {
    test('uses the material after sourceOut up to the source end, then freezes', () {
      final clip = testClip('c', sourceOut: ms(500));
      expect(clip.extendedSourceTimeAt(ms(600), s(1)), ms(600));
      expect(clip.extendedSourceTimeAt(ms(600), ms(500)), ms(500) - us(1));
    });

    test('uses the material before sourceIn down to 0, then freezes', () {
      final clip = testClip('c', start: s(1), sourceIn: ms(200), sourceOut: ms(500));
      expect(clip.extendedSourceTimeAt(ms(900), s(1)), ms(100));
      expect(clip.extendedSourceTimeAt(ms(500), s(1)), Duration.zero);
    });

    test('keeps cycling a looping clip', () {
      final clip = testClip('c', start: s(1), sourceIn: ms(100), sourceOut: ms(400), loopDuration: s(1));
      expect(clip.extendedSourceTimeAt(ms(900), s(1)), ms(300));
      expect(clip.extendedSourceTimeAt(ms(2050), s(1)), ms(250));
    });
  });

  test('fadeAt ramps in and out', () {
    final clip = testClip('c', start: s(1), sourceOut: s(4), fadeIn: s(1), fadeOut: s(2));
    expect(clip.fadeAt(s(1)), 0);
    expect(clip.fadeAt(ms(1500)), closeTo(0.5, 1e-9));
    expect(clip.fadeAt(ms(2500)), 1);
    expect(clip.fadeAt(s(4)), closeTo(0.5, 1e-9));
    expect(clip.fadeAt(s(5)), 0);
  });

  group('validation', () {
    test('rejects speeds outside [0.1, 10]', () {
      expect(() => testClip('c', sourceOut: s(1), speed: 0.05), throwsArgumentError);
      expect(() => testClip('c', sourceOut: s(1), speed: 11), throwsArgumentError);
    });

    test('rejects negative times and an empty trim', () {
      expect(() => testClip('c', start: ms(-1), sourceOut: s(1)), throwsArgumentError);
      expect(() => testClip('c', sourceIn: ms(-1), sourceOut: s(1)), throwsArgumentError);
      expect(() => testClip('c', sourceIn: s(1), sourceOut: s(1)), throwsArgumentError);
      expect(() => testClip('c', sourceOut: s(1), loopDuration: Duration.zero), throwsArgumentError);
      expect(() => testClip('c', sourceOut: s(1), opacity: 1.5), throwsArgumentError);
    });
  });

  test('copyWith can remove the loop', () {
    final clip = testClip('c', sourceOut: s(1), loopDuration: s(3));
    expect(clip.copyWith(removeLoop: true).loopDuration, isNull);
    expect(clip.copyWith(opacity: 0.5).loopDuration, s(3));
  });
}

import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Map<String, Object?> jsonOf(Composition composition) => IcprojCodec.toJson(composition);

Map<String, Object?> sourceOf(Map<String, Object?> json, int clipIndex) {
  final track = (json['tracks']! as List<Object?>).first! as Map<String, Object?>;
  final clip = (track['clips']! as List<Object?>)[clipIndex]! as Map<String, Object?>;
  return clip['source']! as Map<String, Object?>;
}

void main() {
  EffectRef effectRef({Duration? audioOrigin}) => EffectRef(
        effectId: 'icicles.fx.hue_shift',
        effectVersion: 2,
        seed: 9,
        length: s(4),
        audioOrigin: audioOrigin,
        bindings: {
          'shift': const BeatBinding(shape: BeatShape.pulse, periodBeats: 1, min: 0, max: 1),
          'panels': const ConstantBinding(true),
        },
      );

  Composition withEffect({Duration? audioOrigin}) => Composition(
        name: 'Fx',
        target: testSpec(),
        tracks: [
          VisualTrack(id: 't', clips: [
            testClip('f', sourceOut: s(1)),
            testClip('e', source: effectRef(audioOrigin: audioOrigin), start: s(1), sourceIn: ms(500), sourceOut: s(3)),
          ]),
        ],
        audio: AudioRef(path: 'song.mp3', offset: ms(250)),
      );

  group('effect sources', () {
    test('are written as version 2 with type "effect" and round-trip', () {
      final composition = withEffect(audioOrigin: ms(250));
      final json = jsonOf(composition);
      expect(json['version'], 2);
      expect(IcprojCodec.versionFor(composition), 2);
      final source = sourceOf(json, 1);
      expect(source['type'], 'effect');
      expect(source['id'], 'icicles.fx.hue_shift');
      expect(source['version'], 2);
      expect(source['seed'], 9);
      expect(source['lengthUs'], 4000000);
      expect(source['audioOriginUs'], 250000);
      expect((source['params']! as Map<String, Object?>).keys, containsAll(['shift', 'panels']));
      final result = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(result.problems, isEmpty);
      expect(result.composition, composition);
      expect(result.composition.findClip('e')!.clip.source, effectRef(audioOrigin: ms(250)));
      expect(sourceOf(jsonOf(withEffect()), 1).containsKey('audioOriginUs'), isFalse);
    });

    test('salvages effect clips like generator clips', () {
      final json = jsonOf(withEffect());
      final track = (json['tracks']! as List<Object?>).first! as Map<String, Object?>;
      final clip = (track['clips']! as List<Object?>)[1]! as Map<String, Object?>;
      clip['speed'] = 2.0;
      clip['loopDurationUs'] = 5000000;
      clip['mask'] = true;
      clip['sourceOutUs'] = 11 * Duration.microsecondsPerMinute;
      final source = clip['source']! as Map<String, Object?>;
      (source['params']! as Map<String, Object?>)['shift'] = 'garbage';
      source['lengthUs'] = 99 * Duration.microsecondsPerMinute;
      source.remove('seed');
      final result = IcprojCodec.fromJson(json);
      final decoded = result.composition.findClip('e')!.clip;
      final ref = decoded.source as EffectRef;
      expect(decoded.speed, 1.0);
      expect(decoded.loopDuration, isNull);
      expect(decoded.isMask, isFalse);
      expect(ref.length, maxBakeLength);
      expect(decoded.sourceOut, maxBakeLength);
      expect(ref.seed, 0);
      expect(ref.bindings.containsKey('shift'), isFalse);
      expect(ref.bindings['panels'], const ConstantBinding(true));
      expect(
          result.problems.map((p) => p.kind),
          containsAll([
            IcprojProblemKind.defaultedValue,
            IcprojProblemKind.clampedValue,
            IcprojProblemKind.droppedBinding,
          ]));
      expect(result.problems.where((p) => p.path.endsWith('.mask')), hasLength(1));
    });

    test('an effect source without an id drops the clip', () {
      final json = jsonOf(withEffect());
      sourceOf(json, 1).remove('id');
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.findClip('e'), isNull);
      expect(result.problems.map((p) => p.kind), contains(IcprojProblemKind.droppedClip));
    });
  });
}

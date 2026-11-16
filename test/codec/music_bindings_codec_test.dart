import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  test('stem keys, musical times, stem reactivity and adaptive levels round-trip', () {
    final ref = GeneratorRef(
      generatorId: 'icicles.scanner',
      generatorVersion: 1,
      bindings: const {
        'brightness': AudioBinding(feature: AudioFeatureKey.vocals, min: 0.1, max: 1),
        'speed': MusicalBinding(2),
      },
      seed: 3,
      length: s(4),
      audioOrigin: Duration.zero,
      reactivity: AudioReactivity.defaults.copyWith(stem: StemKind.bass, level: AudioLevelMode.adaptive),
    );
    final composition = Composition(
      name: 'Music',
      target: testSpec(),
      tracks: [
        VisualTrack(id: 't', clips: [testClip('g', source: ref, sourceOut: s(4))]),
      ],
      audio: AudioTrack.single(path: 'song.mp3'),
    );
    final result = IcprojCodec.decode(IcprojCodec.encode(composition));
    expect(result.problems, isEmpty);
    expect(result.composition.findClip('g')!.clip.source, ref);
  });
}

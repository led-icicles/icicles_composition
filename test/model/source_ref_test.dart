import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  test('AnimationFileRef is the file source', () {
    final file = ref('a');
    expect(file, AnimationFileRef(path: 'clips/a.anim', contentHash: 'hash-a'));
    expect(file.copyWith(contentHash: 'x').contentHash, 'x');
    expect(file.label, 'clips/a.anim');
    expect(() => AnimationFileRef(path: '', contentHash: ''), throwsArgumentError);
  });

  test('GeneratorRef compares by configuration, bindings by contents', () {
    GeneratorRef make(Map<String, ParamBinding> bindings) =>
        GeneratorRef(generatorId: 'icicles.rain', generatorVersion: 2, bindings: bindings, seed: 5, length: s(3));
    final a = make({'x': const ConstantBinding(1.0), 'color': const ConstantBinding(Color(0xFF00FF00))});
    final b = make({'color': const ConstantBinding(Color(0xFF00FF00)), 'x': const ConstantBinding(1.0)});
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(make({'x': const ConstantBinding(2.0)})));
    expect(a, isNot(a.copyWith(seed: 6)));
    expect(a, isNot(a.copyWith(length: s(4))));
    expect(a, isNot(a.copyWith(audioOrigin: Duration.zero)));
    expect(a.copyWith(audioOrigin: s(1)).usesAudio, isTrue);
    expect(a.copyWith(audioOrigin: s(1)).copyWith(removeAudioOrigin: true).audioOrigin, isNull);
    expect(a.label, 'icicles.rain');
    expect(() => a.bindings['y'] = const ConstantBinding(1.0), throwsUnsupportedError);
    expect(<SourceRef>{a, b, ref('a')}.length, 2);
  });

  test('Tempo and the frame grid come from icicles_generators', () {
    expect(Tempo(bpm: 120).nearestBeat(const Duration(milliseconds: 1400)), const Duration(milliseconds: 1500));
    expect(frameIndexAt(Framerate.fps30, const Duration(seconds: 1)), 30);
    expect(frameCountFor(Framerate.fps30, const Duration(seconds: 1)), 30);
  });
}

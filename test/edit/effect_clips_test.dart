import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Matcher throwsComposition(CompositionErrorKind kind) =>
    throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', kind));

Clip clipOf(Composition composition, String id) => composition.findClip(id)!.clip;

EffectRef effect({Duration length = const Duration(seconds: 4), Duration? audioOrigin}) =>
    EffectRef(effectId: 'icicles.fx.invert', effectVersion: 1, seed: 7, length: length, audioOrigin: audioOrigin);

void main() {
  Clip effectClip(String id,
          {Duration start = Duration.zero,
          Duration sourceIn = Duration.zero,
          Duration? sourceOut,
          Duration? audioOrigin,
          Duration length = const Duration(seconds: 4)}) =>
      testClip(id,
          source: effect(length: length, audioOrigin: audioOrigin),
          start: start,
          sourceIn: sourceIn,
          sourceOut: sourceOut ?? length);

  Composition withClips(List<Clip> clips) => testComposition(tracks: [VisualTrack(id: 't', clips: clips)]);

  EffectRef refOf(Composition composition, String id) => clipOf(composition, id).source as EffectRef;

  group('effect clips', () {
    test('addClip needs no SourceInfo and clamps the trim to the effect length', () {
      final composition = withClips([]).addClip('t', effectClip('e', start: s(1), sourceOut: s(3)));
      final clip = clipOf(composition, 'e');
      expect(clip.start, s(1));
      expect(clip.sourceOut, s(3));
      expect(clip.isEffect, isTrue);
      expect(clip.isParametric, isTrue);
      expect(clip.isGenerator, isFalse);
      final clamped = withClips([]).addClip('t', effectClip('e', sourceOut: s(2), length: s(2)));
      expect(clipOf(clamped, 'e').duration, s(2));
    });

    test('the model refuses speed, loops, masks and a trim beyond the length', () {
      expect(() => testClip('e', source: effect(), sourceOut: s(2), speed: 2), throwsArgumentError);
      expect(() => testClip('e', source: effect(), sourceOut: s(2), loopDuration: s(6)), throwsArgumentError);
      expect(() => testClip('e', source: effect(), sourceOut: s(2), isMask: true), throwsArgumentError);
      expect(() => testClip('e', source: effect(), sourceOut: s(5)), throwsArgumentError);
      expect(() => EffectRef(effectId: '', effectVersion: 1, seed: 1, length: s(1)), throwsArgumentError);
    });

    test('setClipSpeed, setClipLoop and setClipMask refuse to change them', () {
      final composition = withClips([effectClip('e')]);
      expect(() => composition.setClipSpeed('e', 2), throwsComposition(CompositionErrorKind.invalidValue));
      expect(() => composition.setClipLoop('e', enabled: true), throwsComposition(CompositionErrorKind.invalidValue));
      expect(() => composition.setClipMask('e', true), throwsComposition(CompositionErrorKind.invalidValue));
      expect(composition.setClipMask('e', false), composition);
    });

    test('setGeneratorBindings / setEffectBindings and the seed work on effect refs', () {
      final composition = withClips([effectClip('e')]);
      final bound = composition.setEffectBindings('e', {'amount': const ConstantBinding(0.5)}, audioBound: true);
      expect(refOf(bound, 'e').bindings, {'amount': const ConstantBinding(0.5)});
      expect(refOf(bound, 'e').audioOrigin, Duration.zero);
      final seeded = bound.setEffectSeed('e', 99);
      expect(refOf(seeded, 'e').seed, 99);
      expect(refOf(seeded.setGeneratorSeed('e', 5), 'e').seed, 5);
      expect(() => composition.setGeneratorBindings('f', {}), throwsComposition(CompositionErrorKind.clipNotFound));
    });

    test('dragging the end edge grows and shrinks the effect length', () {
      final composition = withClips([effectClip('e', sourceIn: ms(500))]);
      var dragged = composition.dragClipEdge('e', ClipEdge.end, s(10), sourceDuration: s(1));
      expect(refOf(dragged, 'e').length, s(10) + ms(500));
      expect(clipOf(dragged, 'e').end, s(10));
      dragged = dragged.dragClipEdge('e', ClipEdge.end, s(2), sourceDuration: s(1), stretch: true);
      expect(clipOf(dragged, 'e').speed, 1.0);
      expect(refOf(dragged, 'e').length, s(2) + ms(500));
      dragged = dragged.dragClipEdge('e', ClipEdge.end, const Duration(minutes: 30), sourceDuration: s(1));
      expect(refOf(dragged, 'e').length, maxBakeLength);
    });

    test('audio-bound effect clips are re-anchored on every edit', () {
      final composition = withClips([effectClip('e', start: s(2), sourceIn: ms(500), audioOrigin: Duration.zero)])
          .setAudio(AudioTrack.single(path: 'song.mp3', offset: ms(250)));
      expect(refOf(composition, 'e').audioOrigin, s(2) - ms(500) - ms(250));
      final moved = composition.moveClip('e', s(4));
      expect(refOf(moved, 'e').audioOrigin, s(4) - ms(500) - ms(250));
      expect(refOf(composition.setEffectBindings('e', {}, audioBound: false), 'e').audioOrigin, isNull);
    });

    test('applyAttributes copies bindings between clips of the same effect only, never the mask flag', () {
      final other = EffectRef(effectId: 'icicles.fx.tint', effectVersion: 1, seed: 1, length: s(4));
      final mask = testClip('m', sourceOut: s(1), isMask: true, opacity: 0.5);
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          mask,
          effectClip('a', start: s(1)).copyWith(source: effect().copyWith(bindings: {'x': const ConstantBinding(1)})),
          effectClip('b', start: s(6)),
          testClip('c', source: other, start: s(11), sourceOut: s(4)),
        ]),
      ]);
      final applied = composition.applyAttributes(['b', 'c'], clipOf(composition, 'a'));
      expect(refOf(applied, 'b').bindings, {'x': const ConstantBinding(1)});
      expect(refOf(applied, 'b').seed, 7);
      expect(refOf(applied, 'c').bindings, isEmpty);
      final masked = composition.applyAttributes(['b'], mask);
      expect(clipOf(masked, 'b').isMask, isFalse);
      expect(clipOf(masked, 'b').opacity, 0.5);
    });

    test('EffectRef equality: same configuration, never equal to a generator of the same id', () {
      expect(effect(), effect());
      expect(effect(), isNot(effect(audioOrigin: s(1))));
      expect(effect().copyWith(removeAudioOrigin: true), effect());
      final generator = GeneratorRef(generatorId: 'icicles.fx.invert', generatorVersion: 1, seed: 7, length: s(4));
      expect(effect(), isNot(generator));
      expect(effect().label, 'icicles.fx.invert');
      expect(effect().programId, 'icicles.fx.invert');
    });
  });
}

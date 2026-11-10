import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Matcher throwsComposition(CompositionErrorKind kind) =>
    throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', kind));

void main() {
  GeneratorRef generator({Map<String, ParamBinding> bindings = const {}}) =>
      GeneratorRef(generatorId: 'g', generatorVersion: 1, seed: 1, length: s(2), bindings: bindings);

  group('MacroDef', () {
    test('salvages its binding against its own spec and validates the range', () {
      final macro = MacroDef.number(id: 'm', name: 'Intensity', min: 0, max: 2, defaultValue: 5);
      expect(macro.defaultValue, 2, reason: 'the default is clamped into the range');
      expect(macro.binding, const ConstantBinding(2.0));
      expect(macro.spec, isA<NumberParam>().having((p) => p.max, 'max', 2));
      final bound = macro.copyWith(binding: const ConstantBinding(9.0));
      expect(bound.binding, const ConstantBinding(2.0), reason: 'constants are clamped');
      final color = MacroDef.color(id: 'c', name: 'Color A', binding: const ConstantBinding(7.0));
      expect(color.binding, const ConstantBinding(Color(0xFFFFFFFF)), reason: 'a number is not a color');
      expect(() => MacroDef.number(id: '', name: 'x'), throwsArgumentError);
      expect(() => MacroDef.number(id: 'x', name: 'x', min: 1, max: 1), throwsArgumentError);
      expect(() => MacroDef(id: 'x', name: 'x', kind: MacroKind.color, defaultValue: 1.0), throwsArgumentError);
      expect(() => MacroDef(id: 'x', name: 'x\u0000', kind: MacroKind.number), throwsArgumentError);
    });

    test('a macro never reads another macro; keyframes and stacks are kept', () {
      final macro = MacroDef.number(id: 'm', name: 'm', binding: const MacroBinding('other'));
      expect(macro.binding, const MacroBinding('other'),
          reason: 'the spec accepts it (the resolver gives the default); the host hides the option');
      final keyed = MacroDef.number(
        id: 'k',
        name: 'k',
        binding: const KeyframeBinding(keys: [Keyframe(at: 1, value: 0.5), Keyframe(at: 0, value: 3)]),
      );
      expect(
        keyed.binding,
        const KeyframeBinding(keys: [Keyframe(at: 0, value: 1.0), Keyframe(at: 1, value: 0.5)]),
        reason: 'keys sorted and clamped',
      );
    });

    test('macroIdsOf walks stacks, sources and depth bindings', () {
      expect(macroIdsOf(const ConstantBinding(1.0)), isEmpty);
      expect(macroIdsOf(const MacroBinding('a')), {'a'});
      expect(
        macroIdsOf(const StackedBinding(
          base: MacroBinding('a'),
          modulators: [
            Modulator(source: MacroBinding('b'), depth: 1, depthBinding: MacroBinding('c')),
            Modulator(source: BeatBinding(shape: BeatShape.sine, min: 0, max: 1), depth: 1),
          ],
        )),
        {'a', 'b', 'c'},
      );
    });
  });

  group('Composition macros', () {
    test('rejects duplicate ids and exposes the bindings', () {
      final composition = testComposition().copyWith(macros: [
        MacroDef.number(id: 'a', name: 'A', binding: const ConstantBinding(0.5)),
        MacroDef.color(id: 'b', name: 'B'),
      ]);
      expect(composition.macroBindings, {
        'a': const ConstantBinding(0.5),
        'b': const ConstantBinding(Color(0xFFFFFFFF)),
      });
      expect(composition.macroById('b')!.isColor, isTrue);
      expect(
        () => testComposition().copyWith(macros: [
          MacroDef.number(id: 'a', name: 'A'),
          MacroDef.number(id: 'a', name: 'A2'),
        ]),
        throwsArgumentError,
      );
    });

    test('macrosUsedBy keeps only the macros the bindings read', () {
      final composition = testComposition().copyWith(macros: [
        MacroDef.number(id: 'a', name: 'A', binding: const ConstantBinding(0.25)),
        MacroDef.number(id: 'b', name: 'B'),
      ]);
      expect(
        composition.macrosUsedBy({
          'x': const MacroBinding('a'),
          'y': const ConstantBinding(1.0),
          'z': const MacroBinding('missing'),
        }),
        {'a': const ConstantBinding(0.25)},
      );
      expect(composition.macrosUsedBy({'y': const ConstantBinding(1.0)}), isEmpty);
    });

    test('addMacro / updateMacro / setMacroBinding / removeMacro', () {
      var composition = testComposition().addMacro(MacroDef.number(id: 'a', name: 'A', max: 10));
      expect(() => composition.addMacro(MacroDef.number(id: 'a', name: 'A')),
          throwsComposition(CompositionErrorKind.duplicateId));
      composition = composition.updateMacro('a', name: 'Amount', max: 4, defaultValue: 2.0);
      expect(
        composition.macroById('a'),
        MacroDef.number(id: 'a', name: 'Amount', max: 4, defaultValue: 2, binding: const ConstantBinding(0.0)),
        reason: 'a new default leaves the current binding alone',
      );
      composition = composition.setMacroBinding('a', const ConstantBinding(9.0));
      expect(composition.macroById('a')!.binding, const ConstantBinding(4.0), reason: 'salvaged against the spec');
      composition = composition.updateMacro('a', max: 3);
      expect(composition.macroById('a')!.binding, const ConstantBinding(3.0), reason: 're-salvaged on a range change');
      expect(() => composition.updateMacro('a', min: 5), throwsComposition(CompositionErrorKind.invalidValue));
      expect(() => composition.setMacroBinding('zz', const ConstantBinding(1.0)),
          throwsComposition(CompositionErrorKind.macroNotFound));
      expect(() => composition.removeMacro('zz'), throwsComposition(CompositionErrorKind.macroNotFound));
      composition = composition.removeMacro('a');
      expect(composition.macros, isEmpty);
    });

    test('applyAttributes copies macro bindings between clips of one generator', () {
      final from = testClip('a', source: generator(bindings: {'brightness': const MacroBinding('m')}), sourceOut: s(2));
      final to = testClip(
        'b',
        source: generator(bindings: {'brightness': const ConstantBinding(0.5)}),
        start: s(2),
        sourceOut: s(2),
      );
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [from, to])
      ]).addMacro(MacroDef.number(id: 'm', name: 'M')).applyAttributes(['b'], from);
      final source = composition.findClip('b')!.clip.source as GeneratorRef;
      expect(source.bindings['brightness'], const MacroBinding('m'));
      expect(composition.macros, hasLength(1), reason: 'the macros are untouched');
    });
  });

  group('.icproj macros', () {
    test('round-trip as version 2', () {
      final composition = testComposition().copyWith(macros: [
        MacroDef.number(
          id: 'intensity',
          name: 'Intensity',
          min: 0,
          max: 2,
          defaultValue: 1,
          binding: const StackedBinding(
            base:
                KeyframeBinding(keys: [Keyframe(at: 0, value: 0.2), Keyframe(at: 4, value: 1.5, easing: Easing.hold)]),
            modulators: [Modulator(source: AudioBinding(feature: AudioFeatureKey.bass, min: 0, max: 1), depth: 0.4)],
          ),
        ),
        MacroDef.color(id: 'tint', name: 'Tint', defaultValue: const Color(0xFF00FF80)),
      ]);
      final json = IcprojCodec.toJson(composition);
      expect(json['version'], 2);
      final macros = json['macros']! as List<Object?>;
      expect((macros[0]! as Map<String, Object?>)['kind'], 'number');
      expect((macros[1]! as Map<String, Object?>)['defaultColor'], '#00ff80');
      final result = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(result.problems, isEmpty);
      expect(result.composition, composition);
      expect(IcprojCodec.toJson(testComposition()).containsKey('macros'), isFalse);
      expect(IcprojCodec.versionFor(testComposition()), 1);
    });

    test('salvages bad macros: unreadable ones dropped, ranges and bindings repaired', () {
      final json = IcprojCodec.toJson(testComposition())
        ..['version'] = 2
        ..['macros'] = [
          {
            'id': 'ok',
            'name': 'Ok',
            'kind': 'number',
            'min': 1,
            'max': 0,
            'binding': {'type': 'constant', 'value': 7}
          },
          {'name': 'no id'},
          {'id': 'ok', 'name': 'dup', 'kind': 'color'},
          {
            'id': 'c',
            'kind': 'color',
            'defaultColor': 'zzz',
            'binding': {'type': 'nope'}
          },
          'not an object',
        ];
      final result = IcprojCodec.fromJson(json);
      final macros = result.composition.macros;
      expect(macros.map((m) => m.id), ['ok', 'c']);
      expect((macros[0].min, macros[0].max), (0.0, 1.0), reason: 'an inverted range is replaced by 0..1');
      expect(macros[0].binding, const ConstantBinding(1.0), reason: 'the constant is clamped to the range');
      expect(macros[1].name, 'c', reason: 'the id names an unnamed macro');
      expect(macros[1].defaultValue, const Color(0xFFFFFFFF));
      expect(macros[1].binding, const ConstantBinding(Color(0xFFFFFFFF)));
      expect(result.problems.where((p) => p.kind == IcprojProblemKind.droppedMacro), hasLength(3));
      expect(result.problems.where((p) => p.kind == IcprojProblemKind.droppedBinding), hasLength(1));
    });
  });
}

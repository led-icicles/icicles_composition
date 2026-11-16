import 'dart:convert';

import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Composition plain() => testComposition(tracks: [
      VisualTrack(id: 't', clips: [testClip('a', sourceOut: s(1))]),
    ]);

StageLayout layout() => StageLayout(
      name: 'Garaż',
      grid: StagePlacement(index: 0, cx: 10, cy: 20, width: 300, height: 120),
      panels: [
        StagePlacement(index: 3, cx: 5, cy: 6, width: 40, height: 50, rotation: 1.5),
        StagePlacement(index: 1, cx: -5, cy: 7.5, width: 40, height: 50),
      ],
    );

Map<String, Object?> jsonWith(Object? stageLayout) {
  final json = jsonDecode(IcprojCodec.encode(plain().setStageLayout(layout()))) as Map<String, Object?>;
  return {...json, 'stageLayout': stageLayout};
}

void main() {
  test('a project without a layout stays version 1; with one it is version 2 and round-trips', () {
    expect(IcprojCodec.versionFor(plain()), 1);
    expect(jsonDecode(IcprojCodec.encode(plain())), isNot(contains('stageLayout')));

    final composition = plain().setStageLayout(layout());
    expect(composition.stageLayout!.panels.map((p) => p.index), [1, 3], reason: 'sorted by index');
    expect(IcprojCodec.versionFor(composition), 2);
    final json = jsonDecode(IcprojCodec.encode(composition)) as Map<String, Object?>;
    expect((json['stageLayout']! as Map<String, Object?>)['grid'],
        {'cx': 10.0, 'cy': 20.0, 'h': 120.0, 'index': 0, 'rot': 0.0, 'shape': 'rect', 'w': 300.0});
    final result = IcprojCodec.decode(IcprojCodec.encode(composition));
    expect(result.problems, isEmpty);
    expect(result.composition, composition);
    expect(composition.setStageLayout(null).stageLayout, isNull);
    expect(composition.setStageLayout(null), plain());
  });

  test('unreadable placements are dropped one by one, an unreadable layout as a whole', () {
    final result = IcprojCodec.decode(jsonEncode(jsonWith({
      'name': 'x',
      'grid': {'cx': 'no'},
      'panels': [
        {'index': 1, 'cx': 1, 'cy': 2, 'w': 3, 'h': 4, 'rot': 0, 'shape': 'circle'},
        {'index': 1, 'cx': 9, 'cy': 9, 'w': 3, 'h': 4},
        {'index': 0, 'cx': 1, 'cy': 2, 'w': 3, 'h': 4},
        {'index': 2, 'cx': 1, 'cy': 2, 'w': 0, 'h': 4},
        'nope',
      ],
    })));
    final stage = result.composition.stageLayout!;
    expect(stage.grid, isNull);
    expect(stage.panels.single, StagePlacement(index: 1, cx: 1, cy: 2, width: 3, height: 4, shape: 'circle'));
    expect(result.problems.map((p) => p.path), [
      r'$.stageLayout.grid',
      r'$.stageLayout.panels[1]',
      r'$.stageLayout.panels[2]',
      r'$.stageLayout.panels[3]',
      r'$.stageLayout.panels[4]',
    ]);
    expect(result.problems.map((p) => p.kind).toSet(), {IcprojProblemKind.defaultedValue});

    final broken = IcprojCodec.decode(jsonEncode(jsonWith('nope')));
    expect(broken.composition.stageLayout, isNull);
    expect(broken.problems.single.path, r'$.stageLayout');
  });

  test('the model rejects invalid placements', () {
    expect(() => StagePlacement(index: 0, cx: double.nan, cy: 0, width: 1, height: 1), throwsArgumentError);
    expect(() => StagePlacement(index: 0, cx: 0, cy: 0, width: 0, height: 1), throwsArgumentError);
    final panel = StagePlacement(index: 1, cx: 0, cy: 0, width: 1, height: 1);
    expect(() => StageLayout(panels: [panel, panel]), throwsArgumentError);
    expect(() => StageLayout(grid: panel), throwsArgumentError);
    expect(StageLayout().isEmpty, isTrue);
  });
}

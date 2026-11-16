import 'dart:convert';

import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Composition plain() => testComposition(tracks: [
      VisualTrack(id: 't', clips: [testClip('a', sourceOut: s(1))]),
    ]);

Map<String, Object?> json(Composition composition) =>
    jsonDecode(IcprojCodec.encode(composition)) as Map<String, Object?>;

IcprojDecodeResult decodeWith(Map<String, Object?> extra) =>
    IcprojCodec.decode(jsonEncode({...json(plain()), ...extra}));

void main() {
  test('defaults keep version 1 byte for byte', () {
    final c = plain().setTempo(Tempo(bpm: 120));
    expect(IcprojCodec.versionFor(c), 1);
    final encoded = json(c);
    for (final key in ['flashLimit', 'sectionSource', 'physical']) {
      expect(encoded, isNot(contains(key)));
    }
    expect(encoded['tempo'], isNot(contains('beatsPerBar')));
  });

  test('every setting round-trips and needs version 2', () {
    final settings = [
      plain().setTempo(Tempo(bpm: 160, firstBeatOffset: ms(40), beatsPerBar: 3)),
      plain().setFlashLimit(FlashLimit.off),
      plain().setFlashLimit(FlashLimit(8)),
      plain().setSectionSource(SectionSource.markers),
      plain().setPhysical(PhysicalGeometry.installation),
    ];
    for (final c in settings) {
      expect(IcprojCodec.versionFor(c), 2, reason: '$c');
      final back = IcprojCodec.decode(IcprojCodec.encode(c));
      expect(back.problems, isEmpty);
      expect(back.composition, c);
    }
    expect(json(settings[1])['flashLimit'], 'off');
    expect(json(settings[2])['flashLimit'], 8);
  });

  test('unreadable values are salvaged', () {
    final r = decodeWith({
      'version': 2,
      'flashLimit': 'sometimes',
      'sectionSource': 'vibes',
      'physical': {'icicleSpacingCm': 'far'},
      'tempo': {'bpm': 120, 'beatsPerBar': 40},
    });
    final c = r.composition;
    expect(c.flashLimit, FlashLimit.standard);
    expect(c.sectionSource, SectionSource.auto);
    expect(c.tempo!.beatsPerBar, Tempo.maxBeatsPerBar);
    expect(r.problems.map((p) => p.path), containsAll([r'$.flashLimit', r'$.sectionSource', r'$.tempo.beatsPerBar']));
    expect(decodeWith({'version': 2, 'flashLimit': 99}).composition.flashLimit, FlashLimit(30));
  });

  test('flash limit and geometry values', () {
    expect(FlashLimit.standard.exceededBy(4), isTrue);
    expect(FlashLimit.standard.exceededBy(3), isFalse);
    expect(FlashLimit.off.exceededBy(100), isFalse);
    expect(() => FlashLimit(0), throwsArgumentError);
    expect(PhysicalGeometry.installation.pixelAspect, closeTo(15, 1e-9));
    expect(() => PhysicalGeometry(icicleSpacingCm: 0, ledPitchCm: 1), throwsArgumentError);
    expect(plain().setPhysical(PhysicalGeometry.installation).setPhysical(null).physical, isNull);
  });

  test('an exact-length export ends with the timeline', () {
    final anim = solidAnimation([(Colors.red, ms(1077))]);
    final sources = {ref('a'): anim.toIndex()};
    final c = testComposition(tracks: [
      VisualTrack(id: 't', clips: [testClip('a', sourceOut: ms(1077))]),
    ]);
    Duration length(Animation a) => a.frames.fold(Duration.zero, (sum, f) => sum + f.duration);
    expect(length(Compositor.render(c, sources).animation), ms(1100));
    expect(length(Compositor.render(c, sources, exactLength: true).animation), ms(1077));
    final range = LoopRange(start: ms(100), end: ms(450));
    expect(length(Compositor.render(c, sources, range: range, exactLength: true).animation), ms(350));
  });
}

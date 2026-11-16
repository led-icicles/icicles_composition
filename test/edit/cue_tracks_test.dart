import 'dart:convert';

import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart' show CueHit;
import 'package:test/test.dart';

import '../helpers.dart';

GeneratorRef _strobe({String? cueTrackId}) =>
    GeneratorRef(generatorId: 'icicles.strobe', generatorVersion: 2, seed: 1, length: s(4), cueTrackId: cueTrackId);

Composition _base() => Composition(
      name: 'cues',
      target: testSpec(),
      tracks: [
        VisualTrack(id: 't1', clips: [Clip(id: 'c1', source: _strobe(cueTrackId: 'k2'), start: s(1), sourceIn: Duration.zero, sourceOut: s(4))]),
      ],
      cueTracks: [
        CueTrack(id: 'k1', name: 'Kicks'),
        CueTrack(id: 'k2', name: 'Snares', color: ClipLabel.blue),
      ],
    );

void main() {
  group('CueTrack', () {
    test('sorts cues, rejects repeated ids and bad values', () {
      final track = CueTrack(id: 'k', cues: [Cue(id: 'b', at: ms(500)), Cue(id: 'a', at: ms(100), strength: 0.5)]);
      expect(track.cues.map((c) => c.id), ['a', 'b']);
      expect(() => CueTrack(id: 'k', cues: [Cue(id: 'a', at: ms(1)), Cue(id: 'a', at: ms(2))]), throwsArgumentError);
      expect(() => Cue(id: 'x', at: ms(-1)), throwsArgumentError);
      expect(() => Cue(id: 'x', at: ms(1), strength: 1.5), throwsArgumentError);
      expect(track.hits(offset: ms(-100)).hits, [const CueHit(Duration.zero, 0.5), CueHit(ms(400))]);
    });

    test('a clip follows its named track, else the first one', () {
      final composition = _base();
      final source = composition.findClip('c1')!.clip.source as GeneratorRef;
      expect(composition.cueTrackFor(source)?.id, 'k2');
      expect(composition.cueTrackFor(_strobe())?.id, 'k1');
      expect(composition.cueTrackFor(_strobe(cueTrackId: 'gone'))?.id, 'k1');
      expect(Composition(name: 'x', target: testSpec()).cueTrackFor(_strobe()), isNull);
      expect(_strobe(cueTrackId: 'a'), isNot(_strobe(cueTrackId: 'b')), reason: 'part of equality');
    });
  });

  group('edits', () {
    test('add, rename, recolor and remove cue tracks; removal clears the clip references', () {
      var c = _base().addCueTrack(CueTrack(id: 'k3'));
      expect(c.cueTracks.map((t) => t.id), ['k1', 'k2', 'k3']);
      expect(() => c.addCueTrack(CueTrack(id: 'k1')), throwsA(_kind(CompositionErrorKind.duplicateId)));
      c = c.updateCueTrack('k3', name: 'Hats', color: ClipLabel.green);
      expect(c.cueTrackById('k3')!.name, 'Hats');
      expect(c.cueTrackById('k3')!.color, ClipLabel.green);
      expect(() => c.updateCueTrack('nope', name: 'x'), throwsA(_kind(CompositionErrorKind.cueTrackNotFound)));
      c = c.removeCueTrack('k2');
      expect(c.cueTracks.map((t) => t.id), ['k1', 'k3']);
      expect((c.findClip('c1')!.clip.source as GeneratorRef).cueTrackId, isNull);
    });

    test('add, move, set strength, remove and replace cues', () {
      var c = _base().addCues('k1', [Cue(id: 'a', at: ms(200)), Cue(id: 'b', at: ms(800))]);
      expect(() => c.addCues('k1', [Cue(id: 'a', at: ms(1))]), throwsA(_kind(CompositionErrorKind.duplicateId)));
      c = c.moveCues('k1', {'a', 'b'}, ms(-500));
      expect(c.cueTrackById('k1')!.cues.map((cue) => cue.at), [Duration.zero, ms(600)], reason: 'clamped together');
      c = c.setCueStrength('k1', {'b'}, 0.25);
      expect(c.cueTrackById('k1')!.cueById('b')!.strength, 0.25);
      expect(() => c.setCueStrength('k1', {'b'}, 2), throwsA(_kind(CompositionErrorKind.invalidValue)));
      expect(() => c.removeCues('k1', {'zz'}), throwsA(_kind(CompositionErrorKind.cueNotFound)));
      c = c.removeCues('k1', {'a'});
      expect(c.cueTrackById('k1')!.cues.map((cue) => cue.id), ['b']);
      c = c.replaceCues('k1', [Cue(id: 'x', at: s(2))]);
      expect(c.cueTrackById('k1')!.cues.single.id, 'x');
      expect(identical(c.moveCues('k1', {'x'}, Duration.zero), c), isTrue);
    });

    test('setCueTrack names a track and anchors the clip in time on request', () {
      var c = _base().setCueTrack('c1', 'k1', audioBound: true);
      final source = c.findClip('c1')!.clip.source as GeneratorRef;
      expect(source.cueTrackId, 'k1');
      expect(source.audioOrigin, s(1), reason: 'start − sourceIn without a soundtrack');
      c = c.setCueTrack('c1', null);
      expect((c.findClip('c1')!.clip.source as GeneratorRef).cueTrackId, isNull);
      expect(() => c.setCueTrack('c1', 'nope'), throwsA(_kind(CompositionErrorKind.cueTrackNotFound)));
    });

    test('the snapper snaps to cues', () {
      final c = _base().addCues('k1', [Cue(id: 'a', at: ms(1230))]);
      const snapper = Snapper(tolerance: Duration(milliseconds: 20), clipEdges: false);
      expect(snapper.snap(c, ms(1240)), SnapResult(ms(1230), SnapTargetKind.cue));
      expect(snapper.snap(c, ms(1240), ignoreCueIds: {'a'}), isNull);
      expect(const Snapper(tolerance: Duration(milliseconds: 20), cues: false, clipEdges: false).snap(c, ms(1240)),
          isNull);
    });
  });

  group('codec', () {
    test('cue tracks and clip references round-trip and make the document version 2', () {
      final c = _base().addCues('k1', [Cue(id: 'a', at: ms(200)), Cue(id: 'b', at: ms(800), strength: 0.4)]);
      final encoded = IcprojCodec.encode(c);
      expect(IcprojCodec.versionFor(c), 2);
      final decoded = IcprojCodec.decode(encoded);
      expect(decoded.problems, isEmpty);
      expect(decoded.composition, c);
      expect(IcprojCodec.encode(decoded.composition), encoded, reason: 'stable');
    });

    test('unreadable cues and cue tracks are dropped one by one', () {
      final json = IcprojCodec.toJson(_base().addCues('k1', [Cue(id: 'a', at: ms(200))]));
      final tracks = json['cueTracks']! as List<Object?>;
      (tracks[0]! as Map<String, Object?>)['cues'] = {
        'ids': ['a', 'a', 'b', 'c'],
        'us': [100, 200, -5, 300],
        's': [1, 1, 1, 7],
      };
      tracks.add({'name': 'no id'});
      final decoded = IcprojCodec.decode(IcprojCodec.encode(Composition(name: 'x', target: testSpec()))
          .replaceFirst('"markers": []', '"markers": [], "cueTracks": ${jsonEncode(tracks)}'));
      final k1 = decoded.composition.cueTrackById('k1')!;
      expect(k1.cues.map((c) => (c.id, c.at, c.strength)), [('a', us(100), 1.0), ('c', us(300), 1.0)]);
      expect(decoded.problems.where((p) => p.kind == IcprojProblemKind.droppedCue), hasLength(2));
      expect(decoded.problems.where((p) => p.kind == IcprojProblemKind.droppedCueTrack), hasLength(1));
    });
  });
}

Matcher _kind(CompositionErrorKind kind) => isA<CompositionException>().having((e) => e.kind, 'kind', kind);

import 'dart:convert';
import 'dart:io';

import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Map<String, Object?> jsonOf(Composition composition) =>
    jsonDecode(IcprojCodec.encode(composition)) as Map<String, Object?>;

Map<String, Object?> firstTrack(Map<String, Object?> json) =>
    (json['tracks']! as List<Object?>).first! as Map<String, Object?>;

Map<String, Object?> firstClip(Map<String, Object?> json) =>
    (firstTrack(json)['clips']! as List<Object?>).first! as Map<String, Object?>;

Composition plain() => testComposition(tracks: [
      VisualTrack(id: 't', clips: [testClip('a', sourceOut: s(1), loopDuration: s(3))]),
    ]);

void main() {
  group('version 2 timeline craft fields', () {
    test('defaults are omitted and keep a version 1 document byte-identical', () {
      final json = jsonOf(plain());
      expect(json['version'], 1);
      expect(firstClip(json).keys, isNot(contains('reverse')));
      expect(firstClip(json).keys, isNot(contains('pingPong')));
      expect(firstClip(json).keys, isNot(contains('label')));
      expect(firstTrack(json).keys, isNot(contains('solo')));
      expect(json.keys, isNot(contains('loopRange')));
      final text = File('test/codec/fixtures/show_v1.icproj').readAsStringSync();
      expect(IcprojCodec.encode(IcprojCodec.decode(text).composition), text);
    });

    test('each new field makes the document version 2 and round-trips', () {
      final variants = <String, Composition>{
        'reverse': plain().setClipReverse('a', true),
        'pingPong': plain().setClipPingPong('a', true),
        'label': plain().setClipLabel('a', ClipLabel.orange),
        'solo': plain().updateTrack('t', solo: true),
        'marker color': plain().addMarker(Marker(id: 'm', at: s(1), label: 'x', color: ClipLabel.blue)),
        'loopRange': plain().setLoopRange(LoopRange(start: ms(500), end: s(2))),
      };
      for (final MapEntry(key: name, value: composition) in variants.entries) {
        expect(IcprojCodec.versionFor(composition), 2, reason: name);
        final result = IcprojCodec.decode(IcprojCodec.encode(composition));
        expect(result.problems, isEmpty, reason: name);
        expect(result.composition, composition, reason: name);
      }
      final json = jsonOf(variants['loopRange']!);
      expect(json['loopRange'], {'startUs': 500000, 'endUs': 2000000});
      expect(firstClip(jsonOf(variants['label']!))['label'], 'orange');
      expect(firstTrack(jsonOf(variants['solo']!))['solo'], true);
    });

    test('an uncolored marker is written without a color', () {
      final json = jsonOf(plain().addMarker(Marker(id: 'm', at: s(1))));
      expect(json['version'], 1);
      expect(((json['markers']! as List<Object?>).single! as Map<String, Object?>).keys, isNot(contains('color')));
    });

    test('salvages bad values: unknown labels, ping-pong without a loop, a broken loop range', () {
      final json = jsonOf(plain().setLoopRange(LoopRange(start: ms(500), end: s(2))));
      firstClip(json)['label'] = 'teal';
      firstClip(json)['reverse'] = 'yes';
      firstClip(json).remove('loopDurationUs');
      firstClip(json)['pingPong'] = true;
      (json['loopRange']! as Map<String, Object?>)['endUs'] = 100;
      json['markers'] = [
        {'id': 'm', 'atUs': 0, 'label': '', 'color': 'mauve'},
      ];
      final result = IcprojCodec.fromJson(json);
      final clip = result.composition.findClip('a')!.clip;
      expect(clip.label, ClipLabel.none);
      expect(clip.reverse, isFalse);
      expect(clip.pingPong, isFalse);
      expect(result.composition.loopRange, isNull);
      expect(result.composition.markers.single.color, ClipLabel.none);
      expect(
          result.problems.map((problem) => problem.path),
          containsAll([
            r'$.tracks[0].clips[0].label',
            r'$.tracks[0].clips[0].reverse',
            r'$.tracks[0].clips[0].pingPong',
            r'$.loopRange',
            r'$.markers[0].color',
          ]));
      expect(result.problems.every((problem) => problem.kind == IcprojProblemKind.defaultedValue), isTrue);
    });
  });
}

import 'dart:convert';

import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  Composition withAudio(AudioTrack audio) => testComposition().setAudio(audio);

  test('a plain soundtrack is written in the version 1 shape, also with a negative offset', () {
    for (final offset in [Duration.zero, s(2), -ms(120)]) {
      final composition = withAudio(AudioTrack.single(path: 'song.mp3', gain: 0.9, offset: offset));
      expect(IcprojCodec.versionFor(composition), 1);
      final json = IcprojCodec.toJson(composition);
      expect(json['audio'], {'path': 'song.mp3', 'gain': 0.9, 'offsetUs': offset.inMicroseconds});
      final decoded = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(decoded.problems, isEmpty);
      expect(decoded.composition.audio, composition.audio);
    }
  });

  test('segments make the document version 2 and round-trip', () {
    final composition = withAudio(AudioTrack(path: 'song.mp3', gain: 0.5, segments: [
      AudioSegment(id: 'a1', start: s(1), sourceIn: ms(250), sourceOut: s(3)),
      AudioSegment(id: 'a2', start: s(5), sourceIn: s(4)),
    ]));
    expect(IcprojCodec.versionFor(composition), 2);
    final json = IcprojCodec.toJson(composition);
    expect(json['audio'], {
      'path': 'song.mp3',
      'gain': 0.5,
      'segments': [
        {'id': 'a1', 'startUs': 1000000, 'sourceInUs': 250000, 'sourceOutUs': 3000000},
        {'id': 'a2', 'startUs': 5000000, 'sourceInUs': 4000000},
      ],
    });
    final decoded = IcprojCodec.decode(IcprojCodec.encode(composition));
    expect(decoded.problems, isEmpty);
    expect(decoded.composition.audio, composition.audio);
    expect(decoded.composition, composition);
  });

  test('a trimmed single segment is version 2; one trimmed back to the whole file is version 1 again', () {
    final composition = withAudio(AudioTrack.single(path: 'song.mp3'));
    final trimmed = composition.trimAudioSegment('a1', AudioEdge.end, -s(1), sourceLength: s(10));
    expect(IcprojCodec.versionFor(trimmed), 2);
    final whole = trimmed.trimAudioSegment('a1', AudioEdge.end, s(1), sourceLength: s(10));
    expect(IcprojCodec.versionFor(whole), 1);
    expect(IcprojCodec.encode(whole), IcprojCodec.encode(composition));
  });

  test('unreadable and overlapping segments are dropped; without any the audio is dropped', () {
    final composition = withAudio(AudioTrack(path: 'song.mp3', segments: [
      AudioSegment(id: 'a1', start: Duration.zero, sourceOut: s(3)),
      AudioSegment(id: 'a2', start: s(3), sourceOut: s(1)),
    ]));
    final json = IcprojCodec.toJson(composition);
    final audio = json['audio']! as Map<String, Object?>;
    final segments = <Object?>[
      ...audio['segments']! as List<Object?>,
      {'id': 'bad', 'startUs': 2000000, 'sourceOutUs': 1000000},
      {'id': 'overlap', 'startUs': 3500000, 'sourceInUs': 0, 'sourceOutUs': 1000000},
      'nonsense',
    ];
    audio['segments'] = segments;
    var result = IcprojCodec.decode(jsonEncode(json));
    expect(result.composition.audio!.segments.map((segment) => segment.id), ['a1', 'a2']);
    expect(result.problems.map((problem) => problem.kind), everyElement(IcprojProblemKind.droppedAudio));
    expect(result.problems, hasLength(3));

    audio['segments'] = ['nonsense'];
    result = IcprojCodec.decode(jsonEncode(json));
    expect(result.composition.audio, isNull);
    expect(result.problems.map((problem) => problem.path), contains(r'$.audio'));
  });
}

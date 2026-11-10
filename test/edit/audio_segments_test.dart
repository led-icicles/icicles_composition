import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  final fileLength = s(10);

  Composition withAudio({Duration offset = Duration.zero}) =>
      testComposition().setAudio(AudioTrack.single(path: 'song.mp3', offset: offset));

  AudioSegment segment(Composition composition, String id) => composition.audio!.segmentById(id)!;

  group('AudioTrack', () {
    test('single is one open-ended segment; a negative offset skips the file start', () {
      final plain = AudioTrack.single(path: 'song.mp3', offset: s(2));
      expect(plain.isSingleWhole, isTrue);
      expect(plain.offset, s(2));
      expect(plain.first.sourceIn, Duration.zero);
      expect(plain.end, isNull);
      expect(plain.endFor(fileLength), s(12));

      final skipped = AudioTrack.single(path: 'song.mp3', offset: -s(1));
      expect(skipped.isSingleWhole, isTrue);
      expect(skipped.first.start, Duration.zero);
      expect(skipped.first.sourceIn, s(1));
      expect(skipped.offset, -s(1));
    });

    test('rejects overlapping segments, open-ended segments before the last and empty tracks', () {
      expect(() => AudioTrack(path: 'song.mp3', segments: const []), throwsArgumentError);
      expect(
        () => AudioTrack(path: 'song.mp3', segments: [
          AudioSegment(id: 'a', start: Duration.zero, sourceOut: s(3)),
          AudioSegment(id: 'b', start: s(2), sourceOut: s(1)),
        ]),
        throwsArgumentError,
      );
      expect(
        () => AudioTrack(path: 'song.mp3', segments: [
          AudioSegment(id: 'a', start: Duration.zero),
          AudioSegment(id: 'b', start: s(2), sourceOut: s(1)),
        ]),
        throwsArgumentError,
      );
      expect(
        () => AudioTrack(path: 'song.mp3', segments: [
          AudioSegment(id: 'a', start: Duration.zero, sourceOut: s(1)),
          AudioSegment(id: 'a', start: s(2), sourceOut: s(1)),
        ]),
        throwsArgumentError,
      );
    });

    test('segmentAt, segmentFor and offsetAt map timeline time per segment', () {
      final track = AudioTrack(path: 'song.mp3', segments: [
        AudioSegment(id: 'a', start: s(1), sourceIn: Duration.zero, sourceOut: s(2)),
        AudioSegment(id: 'b', start: s(5), sourceIn: s(4)),
      ]);
      expect(track.segmentAt(ms(500)), isNull);
      expect(track.segmentAt(s(1))!.id, 'a');
      expect(track.segmentAt(s(3)), isNull, reason: 'a ends at 3 s');
      expect(track.segmentAt(s(4)), isNull);
      expect(track.segmentAt(s(20))!.id, 'b', reason: 'open-ended without a length');
      expect(track.segmentAt(s(20), sourceLength: fileLength), isNull, reason: 'b ends at 11 s');
      expect(track.segmentFor(ms(500)).id, 'a', reason: 'before everything: the first');
      expect(track.segmentFor(s(4)).id, 'a', reason: 'in a gap: the preceding one');
      expect(track.offsetAt(s(6)), s(1));
      expect(track.offsetAt(s(2)), s(1));
      expect(track.endFor(fileLength), s(11));
    });
  });

  group('setAudioOffset', () {
    test('moves every segment together and keeps the distances', () {
      final split = withAudio().splitAudio(s(3), newSegmentId: 'a2');
      final moved = split.setAudioOffset(s(2));
      expect(segment(moved, 'a1').start, s(2));
      expect(segment(moved, 'a2').start, s(5));
      expect(segment(moved, 'a2').sourceIn, s(3));
      expect(moved.audio!.offset, s(2));
    });

    test('a negative offset skips the start of the file', () {
      final moved = withAudio().setAudioOffset(-s(1));
      expect(moved.audio!.isSingleWhole, isTrue);
      expect(moved.audio!.offset, -s(1));
      expect(segment(moved, 'a1').sourceIn, s(1));
    });

    test('is refused without a soundtrack', () {
      expect(
        () => testComposition().setAudioOffset(s(1)),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidValue)),
      );
    });
  });

  group('splitAudio', () {
    test('splits the segment at the time; the right part continues the file', () {
      final split = withAudio(offset: s(1)).splitAudio(s(4), newSegmentId: 'a2');
      final left = segment(split, 'a1');
      final right = segment(split, 'a2');
      expect(left.start, s(1));
      expect(left.sourceIn, Duration.zero);
      expect(left.sourceOut, s(3));
      expect(left.end, s(4));
      expect(right.start, s(4));
      expect(right.sourceIn, s(3));
      expect(right.isOpenEnded, isTrue);
      expect(split.audio!.offsetAt(s(2)), s(1));
      expect(split.audio!.offsetAt(s(6)), s(1), reason: 'an unmoved split keeps the mapping');
      expect(split.audio!.isSingleWhole, isFalse);
    });

    test('refuses a point outside the segments or too near an edge', () {
      final composition = withAudio(offset: s(1));
      expect(
        () => composition.splitAudio(ms(500), newSegmentId: 'a2'),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidSplit)),
      );
      expect(
        () => composition.splitAudio(s(1), newSegmentId: 'a2'),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidSplit)),
      );
      expect(
        () => composition.splitAudio(s(11), newSegmentId: 'a2', sourceLength: fileLength),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidSplit)),
      );
      expect(
        () => composition.splitAudio(s(4), newSegmentId: 'a1'),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.duplicateId)),
      );
    });
  });

  group('moveAudioSegment', () {
    test('moves a segment into the nearest free gap, never overlapping or before 0', () {
      final split = withAudio().splitAudio(s(3), newSegmentId: 'a2');
      final apart = split.moveAudioSegment('a2', s(5), sourceLength: fileLength);
      expect(segment(apart, 'a2').start, s(5));
      expect(segment(apart, 'a2').sourceIn, s(3));
      expect(apart.audio!.offsetAt(s(6)), s(2), reason: 'the moved segment maps song time 3 s to 5 s');
      expect(apart.audio!.offsetAt(s(4)), Duration.zero, reason: 'the gap keeps the preceding mapping');

      final clamped = apart.moveAudioSegment('a2', s(1), sourceLength: fileLength);
      expect(segment(clamped, 'a2').start, s(3), reason: 'stops at the end of a1');

      final first = apart.moveAudioSegment('a1', -s(2), sourceLength: fileLength);
      expect(segment(first, 'a1').start, Duration.zero);
    });

    test('an open-ended segment without a known length only fits after the others', () {
      final split = withAudio().splitAudio(s(3), newSegmentId: 'a2');
      final moved = split.moveAudioSegment('a2', s(1));
      expect(segment(moved, 'a2').start, s(3));
    });

    test('is refused for an unknown segment', () {
      expect(
        () => withAudio().moveAudioSegment('nope', s(1)),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.audioSegmentNotFound)),
      );
    });
  });

  group('trimAudioSegment', () {
    test('the start edge trims sourceIn and keeps the end; stops at the file start and the neighbour', () {
      final split = withAudio().splitAudio(s(3), newSegmentId: 'a2');
      final trimmed = split.trimAudioSegment('a2', AudioEdge.start, s(1), sourceLength: fileLength);
      final right = segment(trimmed, 'a2');
      expect(right.start, s(4));
      expect(right.sourceIn, s(4));
      expect(right.isOpenEnded, isTrue);
      expect(trimmed.audio!.offsetAt(s(5)), Duration.zero);

      final back = trimmed.trimAudioSegment('a2', AudioEdge.start, -s(5), sourceLength: fileLength);
      expect(segment(back, 'a2').start, s(3), reason: 'stops at the end of a1');

      final first = split.trimAudioSegment('a1', AudioEdge.start, -s(1), sourceLength: fileLength);
      expect(identical(first, split), isTrue, reason: 'already at the file start');
    });

    test('the end edge trims sourceOut; the file end leaves it open-ended', () {
      final split = withAudio().splitAudio(s(3), newSegmentId: 'a2');
      final shorter = split.trimAudioSegment('a1', AudioEdge.end, -s(1), sourceLength: fileLength);
      expect(segment(shorter, 'a1').sourceOut, s(2));
      expect(segment(shorter, 'a1').end, s(2));

      final longer = shorter.trimAudioSegment('a1', AudioEdge.end, s(5), sourceLength: fileLength);
      expect(segment(longer, 'a1').sourceOut, s(3), reason: 'stops at the start of a2');

      final open = split.trimAudioSegment('a2', AudioEdge.end, -s(2), sourceLength: fileLength);
      expect(segment(open, 'a2').sourceOut, s(8));
      final full = open.trimAudioSegment('a2', AudioEdge.end, s(3), sourceLength: fileLength);
      expect(segment(full, 'a2').isOpenEnded, isTrue);

      expect(
        () => split.trimAudioSegment('a2', AudioEdge.end, -s(1)),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.invalidValue)),
        reason: 'an open-ended end needs the file length',
      );
    });

    test('never shorter than the minimum', () {
      final split = withAudio().splitAudio(s(3), newSegmentId: 'a2');
      final tiny = split.trimAudioSegment('a1', AudioEdge.end, -s(10), sourceLength: fileLength);
      expect(segment(tiny, 'a1').duration, AudioSegment.minDuration);
      final tinyStart = split.trimAudioSegment('a1', AudioEdge.start, s(10), sourceLength: fileLength);
      expect(segment(tinyStart, 'a1').duration, AudioSegment.minDuration);
      expect(segment(tinyStart, 'a1').end, s(3));
    });
  });

  group('removeAudioSegment and setAudioGain', () {
    test('removing a segment keeps the others; the last one removes the track', () {
      final split = withAudio().splitAudio(s(3), newSegmentId: 'a2');
      final one = split.removeAudioSegment('a1');
      expect(one.audio!.segments.map((segment) => segment.id), ['a2']);
      expect(one.removeAudioSegment('a2').audio, isNull);
    });

    test('setAudioGain clamps to the range', () {
      expect(withAudio().setAudioGain(0.5).audio!.gain, 0.5);
      expect(withAudio().setAudioGain(9).audio!.gain, AudioTrack.maxGain);
      expect(withAudio().setAudioGain(-1).audio!.gain, 0);
    });
  });

  group('audioOriginFor', () {
    GeneratorRef generator({Duration? audioOrigin}) =>
        GeneratorRef(generatorId: 'g', generatorVersion: 1, seed: 1, length: s(2), audioOrigin: audioOrigin);

    test('uses the mapping of the segment at the clip start (the preceding one in a gap)', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          testClip('early', source: generator(audioOrigin: Duration.zero), start: s(1), sourceOut: s(2)),
          testClip('late', source: generator(audioOrigin: Duration.zero), start: s(6), sourceOut: s(2)),
          testClip('gap', source: generator(audioOrigin: Duration.zero), start: s(4), sourceOut: s(1)),
        ]),
      ]).setAudio(AudioTrack(path: 'song.mp3', segments: [
        AudioSegment(id: 'a', start: Duration.zero, sourceOut: s(3)),
        AudioSegment(id: 'b', start: s(5), sourceIn: s(6)),
      ]));
      GeneratorRef refOf(String id) => composition.findClip(id)!.clip.source as GeneratorRef;
      expect(refOf('early').audioOrigin, s(1));
      expect(refOf('late').audioOrigin, s(7), reason: '6 s − (5 s − 6 s)');
      expect(refOf('gap').audioOrigin, s(4), reason: 'the gap after a keeps a\'s mapping');

      final moved = composition.moveAudioSegment('b', s(8), sourceLength: fileLength);
      expect((moved.findClip('late')!.clip.source as GeneratorRef).audioOrigin, s(6),
          reason: 'the clip now lies in the gap: a\'s mapping');
    });
  });
}

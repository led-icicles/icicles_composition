import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Matcher throwsComposition(CompositionErrorKind kind) =>
    throwsA(isA<CompositionException>().having((error) => error.kind, 'kind', kind));

final source = SourceInfo.of(solidAnimation([(Colors.red, s(5))]));

Composition withClips(List<Clip> clips, {bool locked = false, List<Transition> transitions = const []}) =>
    testComposition(tracks: [VisualTrack(id: 't', clips: clips, locked: locked, transitions: transitions)]);

Clip clipOf(Composition composition, String id) => composition.findClip(id)!.clip;

void expectNoOverlap(Composition composition) {
  for (final track in composition.tracks) {
    for (var i = 1; i < track.clips.length; i++) {
      expect(track.clips[i - 1].end <= track.clips[i].start, isTrue, reason: 'clips ${i - 1} and $i overlap');
    }
    for (final clip in track.clips) {
      expect(clip.start.isNegative, isFalse);
      expect(clip.sourceIn.isNegative, isFalse);
      expect(clip.speed, inInclusiveRange(Clip.minSpeed, Clip.maxSpeed));
    }
  }
}

void main() {
  group('tracks', () {
    test('add, reorder, update and remove', () {
      var composition = testComposition()
          .addTrack(VisualTrack(id: 'a'))
          .addTrack(VisualTrack(id: 'b'))
          .addTrack(VisualTrack(id: 'c'), index: 0);
      expect(composition.tracks.map((track) => track.id), ['c', 'a', 'b']);
      composition = composition.reorderTrack('c', 2).updateTrack('a', muted: true, opacity: 3);
      expect(composition.tracks.map((track) => track.id), ['a', 'b', 'c']);
      expect(composition.trackById('a')!.muted, isTrue);
      expect(composition.trackById('a')!.opacity, 1.0);
      expect(composition.removeTrack('b').tracks.map((track) => track.id), ['a', 'c']);
      expect(() => composition.addTrack(VisualTrack(id: 'a')), throwsComposition(CompositionErrorKind.duplicateId));
      expect(() => composition.removeTrack('x'), throwsComposition(CompositionErrorKind.trackNotFound));
    });
  });

  group('addClip', () {
    test('rejects a source with another layout', () {
      final other = SourceInfo.of(solidAnimation([(Colors.red, s(1))], xCount: 2, yCount: 3));
      final panels = SourceInfo.of(solidAnimation([(Colors.red, s(1))], radioPanelsCount: 1));
      final composition = withClips([]);
      final clip = testClip('c', sourceOut: s(1));
      expect(() => composition.addClip('t', clip, other), throwsComposition(CompositionErrorKind.layoutMismatch));
      expect(() => composition.addClip('t', clip, panels), throwsComposition(CompositionErrorKind.layoutMismatch));
    });

    test('clamps the trim to the source and places the clip in a free gap', () {
      final composition =
          withClips([testClip('a', sourceOut: s(2))]).addClip('t', testClip('b', start: s(1), sourceOut: s(9)), source);
      final added = clipOf(composition, 'b');
      expect(added.sourceOut, s(5));
      expect(added.start, s(2));
      expectNoOverlap(composition);
    });

    test('refuses locked tracks and repeated ids', () {
      expect(
        () => withClips([], locked: true).addClip('t', testClip('c', sourceOut: s(1)), source),
        throwsComposition(CompositionErrorKind.trackLocked),
      );
      expect(
        () => withClips([testClip('c', sourceOut: s(1))]).addClip('t', testClip('c', sourceOut: s(1)), source),
        throwsComposition(CompositionErrorKind.duplicateId),
      );
    });
  });

  group('moveClip', () {
    final composition = withClips([
      testClip('a', sourceOut: s(2)),
      testClip('b', start: s(3), sourceOut: s(1)),
      testClip('c', start: s(6), sourceOut: s(2)),
    ]);

    test('clamps an overlap to the neighbour edge', () {
      expect(clipOf(composition.moveClip('b', ms(1500)), 'b').start, s(2));
      expect(clipOf(composition.moveClip('b', ms(5500)), 'b').start, s(5));
    });

    test('never moves before the timeline start', () {
      expect(clipOf(composition.moveClip('a', ms(-500)), 'a').start, Duration.zero);
    });

    test('lands in the nearest gap that fits', () {
      // b (1 s) dropped in the middle of c jumps to the nearest free gap.
      final moved = composition.moveClip('b', ms(6900));
      expect(clipOf(moved, 'b').start, s(8));
      expectNoOverlap(moved);
    });

    test('moves across tracks and drops its transitions', () {
      final withTransition = composition
          .moveClip('b', s(2))
          .addTransition(Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(500)));
      expect(withTransition.trackById('t')!.transitions, hasLength(1));
      final moved = withTransition.addTrack(VisualTrack(id: 'u')).moveClip('b', s(1), toTrackId: 'u');
      expect(moved.findClip('b')!.track.id, 'u');
      expect(moved.trackById('t')!.transitions, isEmpty);
    });
  });

  group('dragClipEdge, plain (trim)', () {
    final composition = withClips([
      testClip('a', sourceOut: s(1)),
      testClip('b', start: s(2), sourceIn: s(1), sourceOut: s(2)),
      testClip('c', start: s(4), sourceOut: s(1)),
    ]);

    test('the end edge moves sourceOut and stops at the next clip', () {
      final trimmed = composition.dragClipEdge('b', ClipEdge.end, ms(2500), sourceDuration: s(5));
      expect(clipOf(trimmed, 'b').sourceOut, ms(1500));
      final clamped = composition.dragClipEdge('b', ClipEdge.end, s(10), sourceDuration: s(5));
      expect(clipOf(clamped, 'b').end, s(4));
      expect(clipOf(clamped, 'b').sourceOut, s(3));
    });

    test('the end edge stops at the source end', () {
      final clamped = composition.dragClipEdge('b', ClipEdge.end, s(10), sourceDuration: ms(2500));
      expect(clipOf(clamped, 'b').sourceOut, ms(2500));
    });

    test('the start edge moves sourceIn, keeps the end and stops at sourceIn 0 or the previous clip', () {
      final trimmed = composition.dragClipEdge('b', ClipEdge.start, ms(2500), sourceDuration: s(5));
      expect(clipOf(trimmed, 'b').sourceIn, ms(1500));
      expect(clipOf(trimmed, 'b').end, s(3));
      final toZero = composition.dragClipEdge('b', ClipEdge.start, ms(1500), sourceDuration: s(5));
      expect(clipOf(toZero, 'b').sourceIn, ms(500));
      final atNeighbour =
          withClips([testClip('a', sourceOut: s(1)), testClip('b', start: s(2), sourceIn: s(3), sourceOut: s(4))])
              .dragClipEdge('b', ClipEdge.start, Duration.zero, sourceDuration: s(5));
      expect(clipOf(atNeighbour, 'b').start, s(1));
      expect(clipOf(atNeighbour, 'b').sourceIn, s(2));
    });

    test('keeps at least the minimum duration', () {
      final trimmed = composition.dragClipEdge('b', ClipEdge.end, Duration.zero, sourceDuration: s(5));
      expect(clipOf(trimmed, 'b').duration, Clip.minDuration);
    });

    test('clamps to neighbours at slow speeds without overlapping', () {
      final slow = withClips([
        testClip('a', sourceOut: us(1234567), speed: 0.3),
        testClip('b', start: s(5), sourceOut: s(1)),
      ]);
      final trimmed = slow.dragClipEdge('a', ClipEdge.end, s(9), sourceDuration: s(5));
      expect(clipOf(trimmed, 'a').end, closeToDuration(s(5), us(4)));
      expectNoOverlap(trimmed);
    });
  });

  group('dragClipEdge on a looping clip', () {
    final composition = withClips([
      testClip('a', start: s(1), sourceIn: ms(100), sourceOut: ms(600), loopDuration: s(2)),
      testClip('b', start: s(5), sourceOut: s(1)),
    ]);

    test('the end edge sets loopDuration and keeps the trim', () {
      final dragged = clipOf(composition.dragClipEdge('a', ClipEdge.end, ms(4200), sourceDuration: s(5)), 'a');
      expect(dragged.loopDuration, ms(3200));
      expect((dragged.sourceIn, dragged.sourceOut, dragged.speed), (ms(100), ms(600), 1.0));
      final clamped = clipOf(composition.dragClipEdge('a', ClipEdge.end, s(9), sourceDuration: s(5)), 'a');
      expect(clamped.end, s(5));
    });

    test('the start edge trims sourceIn and keeps the end fixed', () {
      final dragged = clipOf(composition.dragClipEdge('a', ClipEdge.start, ms(1200), sourceDuration: s(5)), 'a');
      expect(dragged.start, ms(1200));
      expect(dragged.sourceIn, ms(300));
      expect(dragged.end, s(3));
      final extended = clipOf(composition.dragClipEdge('a', ClipEdge.start, ms(500), sourceDuration: s(5)), 'a');
      expect(extended.start, ms(500));
      expect(extended.sourceIn, Duration.zero);
      expect(extended.end, s(3));
    });
  });

  group('dragClipEdge with stretch (Shift)', () {
    test('changes the speed and keeps the trim', () {
      final composition = withClips([testClip('a', start: s(1), sourceIn: s(1), sourceOut: s(3))]);
      final slower =
          clipOf(composition.dragClipEdge('a', ClipEdge.end, s(5), sourceDuration: s(5), stretch: true), 'a');
      expect(slower.speed, closeTo(0.5, 1e-12));
      expect((slower.sourceIn, slower.sourceOut, slower.start), (s(1), s(3), s(1)));
      expect(slower.end, closeToDuration(s(5)));
      final faster =
          clipOf(composition.dragClipEdge('a', ClipEdge.start, s(2), sourceDuration: s(5), stretch: true), 'a');
      expect(faster.speed, closeTo(2, 1e-12));
      expect(faster.end, closeToDuration(s(3)));
      expect(faster.start, closeToDuration(s(2)));
    });

    test('scales loopDuration of a looping clip', () {
      final composition = withClips([testClip('a', sourceOut: ms(500), loopDuration: s(2))]);
      final stretched =
          clipOf(composition.dragClipEdge('a', ClipEdge.end, s(4), sourceDuration: s(5), stretch: true), 'a');
      expect(stretched.speed, closeTo(0.5, 1e-12));
      expect(stretched.loopDuration, s(4));
      expect(stretched.passDuration, s(1));
      expect((stretched.sourceIn, stretched.sourceOut), (Duration.zero, ms(500)));
    });

    test('respects the speed bounds and the neighbours', () {
      final composition = withClips([testClip('a', sourceOut: s(1)), testClip('b', start: s(3), sourceOut: s(1))]);
      final tooSlow =
          clipOf(composition.dragClipEdge('a', ClipEdge.end, s(60), sourceDuration: s(5), stretch: true), 'a');
      expect(tooSlow.end, closeToDuration(s(3)));
      final fastest =
          clipOf(composition.dragClipEdge('a', ClipEdge.end, us(1), sourceDuration: s(5), stretch: true), 'a');
      expect(fastest.speed, Clip.maxSpeed);
      expect(fastest.duration, ms(100));
    });
  });

  test('setClipSpeed keeps start and trim, scales a loop and clamps to the next clip', () {
    final composition = withClips([
      testClip('a', sourceOut: s(1), loopDuration: s(2)),
      testClip('b', start: s(5), sourceOut: s(1)),
    ]);
    final half = clipOf(composition.setClipSpeed('a', 0.5), 'a');
    expect(half.loopDuration, s(4));
    final clamped = clipOf(composition.setClipSpeed('a', 0.1), 'a');
    expect(clamped.end, s(5));
    expect(clipOf(composition.setClipSpeed('a', 100), 'a').speed, Clip.maxSpeed);
  });

  group('setClipLoop', () {
    test('on keeps the length, off clamps to one pass', () {
      final composition = withClips([testClip('a', sourceOut: s(1))]);
      final looped = composition.setClipLoop('a', enabled: true);
      expect(clipOf(looped, 'a').loopDuration, s(1));
      final longer = looped.dragClipEdge('a', ClipEdge.end, s(3), sourceDuration: s(5));
      expect(clipOf(longer, 'a').duration, s(3));
      final off = clipOf(longer.setClipLoop('a', enabled: false), 'a');
      expect(off.loopDuration, isNull);
      expect(off.duration, s(1));
    });

    test('off turns a loop shorter than one pass into the same trim', () {
      final composition = withClips([testClip('a', sourceIn: ms(200), sourceOut: s(2), loopDuration: ms(500))]);
      final off = clipOf(composition.setClipLoop('a', enabled: false), 'a');
      expect((off.sourceIn, off.sourceOut, off.duration), (ms(200), ms(700), ms(500)));
    });
  });

  group('splitClip', () {
    test('keeps the total coverage', () {
      for (final speed in [1.0, 0.7, 3.3]) {
        final original = testClip('a',
            start: s(1), sourceIn: ms(100), sourceOut: us(2345678), speed: speed, fadeIn: ms(10), fadeOut: ms(20));
        // A neighbour right at the end: the right part must not overlap it.
        final composition = withClips([original, testClip('n', start: original.end, sourceOut: s(1))]);
        final split = composition.splitClip('a', original.start + original.duration * 0.4137, newClipId: 'r');
        final left = clipOf(split, 'a');
        final right = clipOf(split, 'r');
        expect(left.start, original.start);
        expect(right.start, left.end);
        expect(right.end, closeToDuration(original.end, us(10)));
        expect(right.end <= original.end, isTrue);
        expect(right.sourceIn, left.sourceOut);
        expect(
            (left.fadeIn, left.fadeOut, right.fadeIn, right.fadeOut), (ms(10), Duration.zero, Duration.zero, ms(20)));
        expectNoOverlap(split);
      }
    });

    test('splits a looping clip and continues the pass when the rest fits in it', () {
      final composition = withClips([testClip('a', sourceOut: s(1), loopDuration: ms(1800))]);
      final split = composition.splitClip('a', ms(1200), newClipId: 'r');
      expect(clipOf(split, 'a').loopDuration, ms(1200));
      final right = clipOf(split, 'r');
      expect((right.start, right.sourceIn, right.sourceOut, right.loopDuration), (ms(1200), ms(200), ms(800), null));
    });

    test('keeps a looping right part when the split is on a pass boundary', () {
      final composition = withClips([testClip('a', sourceOut: s(1), loopDuration: s(3))]);
      final right = clipOf(composition.splitClip('a', s(1), newClipId: 'r'), 'r');
      expect((right.start, right.sourceIn, right.loopDuration), (s(1), Duration.zero, s(2)));
    });

    test('moves the outgoing transition to the right part', () {
      final composition = withClips(
        [testClip('a', sourceOut: s(2)), testClip('b', start: s(2), sourceOut: s(2))],
        transitions: [Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(400))],
      );
      final split = composition.splitClip('a', s(1), newClipId: 'r');
      expect(split.trackById('t')!.transitions.single.fromClipId, 'r');
    });

    test('rejects split points outside the clip', () {
      final composition = withClips([testClip('a', start: s(1), sourceOut: s(1))]);
      expect(
          () => composition.splitClip('a', s(1), newClipId: 'r'), throwsComposition(CompositionErrorKind.invalidSplit));
      expect(
          () => composition.splitClip('a', s(3), newClipId: 'r'), throwsComposition(CompositionErrorKind.invalidSplit));
    });
  });

  test('removeClip drops the clip and its transitions', () {
    final composition = withClips(
      [testClip('a', sourceOut: s(1)), testClip('b', start: s(1), sourceOut: s(1))],
      transitions: [Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(400))],
    );
    final removed = composition.removeClip('b');
    expect(removed.trackById('t')!.clips.map((clip) => clip.id), ['a']);
    expect(removed.trackById('t')!.transitions, isEmpty);
  });

  test('duplicateClip places the copy after the original', () {
    final composition = withClips([testClip('a', sourceOut: s(1)), testClip('b', start: ms(1500), sourceOut: s(1))]);
    final duplicated = composition.duplicateClip('a', newClipId: 'a2');
    expect(clipOf(duplicated, 'a2').start, ms(2500));
    expect(clipOf(duplicated, 'a2').source, clipOf(composition, 'a').source);
    expectNoOverlap(duplicated);
  });

  test('setClipProps clamps opacity and fades', () {
    final composition = withClips([testClip('a', sourceOut: s(1))]);
    final clip = clipOf(
      composition.setClipProps('a',
          opacity: 2, fadeIn: s(5), fadeOut: ms(-5), blend: BlendMode.add, region: const Region.iciclesOnly()),
      'a',
    );
    expect((clip.opacity, clip.fadeIn, clip.fadeOut, clip.blend, clip.region),
        (1.0, s(1), Duration.zero, BlendMode.add, const Region.iciclesOnly()));
  });

  test('setClipMask and setClipProps(isMask:) toggle the mask flag', () {
    final composition = withClips([testClip('a', sourceOut: s(1))]);
    final masked = composition.setClipMask('a', true);
    expect(clipOf(masked, 'a').isMask, isTrue);
    expect(clipOf(masked.setClipProps('a', isMask: false), 'a').isMask, isFalse);
    expect(clipOf(masked.setClipProps('a', opacity: 0.5), 'a').isMask, isTrue);
    final locked = withClips([testClip('a', sourceOut: s(1))], locked: true);
    expect(() => locked.setClipMask('a', true), throwsComposition(CompositionErrorKind.trackLocked));
  });

  test('locked tracks refuse clip edits', () {
    final composition = withClips([testClip('a', sourceOut: s(1))], locked: true);
    expect(() => composition.moveClip('a', s(1)), throwsComposition(CompositionErrorKind.trackLocked));
    expect(() => composition.removeClip('a'), throwsComposition(CompositionErrorKind.trackLocked));
    expect(() => composition.setClipProps('a', opacity: 0.5), throwsComposition(CompositionErrorKind.trackLocked));
    expect(composition.updateTrack('t', locked: false).moveClip('a', s(1)).findClip('a')!.clip.start, s(1));
  });

  group('transitions', () {
    final composition = withClips([
      testClip('a', sourceOut: s(2)),
      testClip('b', start: s(2), sourceOut: ms(500)),
      testClip('c', start: s(4), sourceOut: s(1)),
    ]);

    test('are limited to the shorter clip', () {
      final added = composition.addTransition(Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: s(3)));
      expect(added.trackById('t')!.transitionById('x')!.duration, ms(500));
      final updated = added.updateTransition('x', duration: ms(200), alignment: TransitionAlignment.startAtCut);
      expect(updated.trackById('t')!.transitionById('x')!.duration, ms(200));
      expect(updated.removeTransition('x').trackById('t')!.transitions, isEmpty);
    });

    test('need adjacent clips', () {
      expect(
        () => composition.addTransition(Transition(id: 'x', fromClipId: 'b', toClipId: 'c', duration: ms(100))),
        throwsComposition(CompositionErrorKind.notAdjacent),
      );
      expect(
        () => composition.addTransition(Transition(id: 'x', fromClipId: 'a', toClipId: 'q', duration: ms(100))),
        throwsComposition(CompositionErrorKind.clipNotFound),
      );
    });

    test('are removed when a trim separates the clips', () {
      final added = composition.addTransition(Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(400)));
      final trimmed = added.dragClipEdge('a', ClipEdge.end, s(1), sourceDuration: s(5));
      expect(trimmed.trackById('t')!.transitions, isEmpty);
    });

    test('are shortened when a clip gets shorter', () {
      final added = composition.addTransition(Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(500)));
      final trimmed = added.dragClipEdge('b', ClipEdge.end, ms(2300), sourceDuration: s(5));
      expect(trimmed.trackById('t')!.transitionById('x')!.duration, ms(300));
    });
  });

  test('markers, audio and tempo', () {
    var composition = testComposition()
        .addMarker(Marker(id: 'm2', at: s(2)))
        .addMarker(Marker(id: 'm1', at: s(1), label: 'drop'))
        .setAudio(AudioTrack.single(path: 'music.mp3', gain: 0.8))
        .setTempo(Tempo(bpm: 128));
    expect(composition.markers.map((marker) => marker.id), ['m1', 'm2']);
    composition = composition.updateMarker('m2', at: ms(-3)).removeMarker('m1');
    expect(composition.markers.single.at, Duration.zero);
    expect(composition.setAudio(null).audio, isNull);
    expect(composition.setTempo(null).tempo, isNull);
    expect(composition.tempo!.bpm, 128);
  });

  group('generator clips', () {
    GeneratorRef generator({Duration length = const Duration(seconds: 4), Duration? audioOrigin}) => GeneratorRef(
        generatorId: 'icicles.rain', generatorVersion: 1, seed: 7, length: length, audioOrigin: audioOrigin);

    Clip generatorClip(String id,
            {Duration start = Duration.zero,
            Duration sourceIn = Duration.zero,
            Duration? sourceOut,
            Duration? audioOrigin,
            Duration length = const Duration(seconds: 4)}) =>
        testClip(id,
            source: generator(length: length, audioOrigin: audioOrigin),
            start: start,
            sourceIn: sourceIn,
            sourceOut: sourceOut ?? length);

    GeneratorRef refOf(Composition composition, String id) => clipOf(composition, id).source as GeneratorRef;

    test('addClip needs no SourceInfo and clamps the trim to the generator length', () {
      final composition = withClips([]).addClip('t', generatorClip('g', start: s(1), sourceOut: s(3)));
      expect(clipOf(composition, 'g').start, s(1));
      expect(clipOf(composition, 'g').sourceOut, s(3));
      expect(clipOf(composition, 'g').isGenerator, isTrue);
      expect(() => withClips([]).addClip('t', testClip('f', sourceOut: s(1))),
          throwsComposition(CompositionErrorKind.invalidValue));
    });

    test('the model refuses speed, loops and a trim beyond the length', () {
      expect(() => testClip('g', source: generator(), sourceOut: s(2), speed: 2), throwsArgumentError);
      expect(() => testClip('g', source: generator(), sourceOut: s(2), loopDuration: s(6)), throwsArgumentError);
      expect(() => testClip('g', source: generator(), sourceOut: s(5)), throwsArgumentError);
      expect(() => generator(length: const Duration(minutes: 11)), throwsArgumentError);
      expect(() => generator(length: Duration.zero), throwsArgumentError);
    });

    test('setClipSpeed and setClipLoop refuse to change them', () {
      final composition = withClips([generatorClip('g')]);
      expect(() => composition.setClipSpeed('g', 2), throwsComposition(CompositionErrorKind.invalidValue));
      expect(composition.setClipSpeed('g', 1), composition);
      expect(() => composition.setClipLoop('g', enabled: true), throwsComposition(CompositionErrorKind.invalidValue));
      expect(composition.setClipLoop('g', enabled: false), composition);
    });

    test('dragging the end edge grows and shrinks the generator length, clamped at maxBakeLength', () {
      final composition = withClips([generatorClip('g', sourceIn: ms(500))]);
      var dragged = composition.dragClipEdge('g', ClipEdge.end, s(10), sourceDuration: s(1));
      expect(clipOf(dragged, 'g').sourceOut, s(10) + ms(500));
      expect(refOf(dragged, 'g').length, s(10) + ms(500));
      expect(clipOf(dragged, 'g').end, s(10));

      dragged = dragged.dragClipEdge('g', ClipEdge.end, s(2), sourceDuration: s(1), stretch: true);
      expect(clipOf(dragged, 'g').speed, 1.0);
      expect(clipOf(dragged, 'g').sourceOut, s(2) + ms(500));
      expect(refOf(dragged, 'g').length, s(2) + ms(500));

      dragged = dragged.dragClipEdge('g', ClipEdge.end, const Duration(minutes: 30), sourceDuration: s(1));
      expect(refOf(dragged, 'g').length, maxBakeLength);
      expect(clipOf(dragged, 'g').sourceOut, maxBakeLength);
      expectNoOverlap(dragged);
    });

    test('the end edge stops at the next clip', () {
      final composition = withClips([generatorClip('g', sourceOut: s(2)), testClip('b', start: s(3), sourceOut: s(1))]);
      final dragged = composition.dragClipEdge('g', ClipEdge.end, s(8), sourceDuration: s(1));
      expect(clipOf(dragged, 'g').end, s(3));
      expect(refOf(dragged, 'g').length, s(3));
      expectNoOverlap(dragged);
    });

    test('dragging the start edge trims sourceIn and keeps the length', () {
      final composition = withClips([generatorClip('g', start: s(1))]);
      final dragged = composition.dragClipEdge('g', ClipEdge.start, s(2), sourceDuration: s(1));
      expect(clipOf(dragged, 'g').start, s(2));
      expect(clipOf(dragged, 'g').sourceIn, s(1));
      expect(clipOf(dragged, 'g').end, s(5));
      expect(refOf(dragged, 'g').length, s(4));
      final back = dragged.dragClipEdge('g', ClipEdge.start, Duration.zero, sourceDuration: s(1));
      expect(clipOf(back, 'g').sourceIn, Duration.zero);
      expect(clipOf(back, 'g').start, s(1));
    });

    test('setGeneratorBindings and setGeneratorSeed replace the ref of that clip only', () {
      const bindings = {'speed': ConstantBinding(2.0)};
      final composition = withClips(
          [generatorClip('g'), generatorClip('h', start: s(5)), testClip('f', start: s(10), sourceOut: s(1))]);
      final edited = composition.setGeneratorBindings('g', bindings).setGeneratorSeed('g', 99);
      expect(refOf(edited, 'g').bindings, bindings);
      expect(refOf(edited, 'g').seed, 99);
      expect(refOf(edited, 'h'), generator());
      expect(edited.sources.length, 3);
      expect(() => composition.setGeneratorSeed('f', 1), throwsComposition(CompositionErrorKind.invalidValue));
      expect(
          () => composition.setGeneratorBindings('f', bindings), throwsComposition(CompositionErrorKind.invalidValue));
      expect(() => composition.setGeneratorSeed('x', 1), throwsComposition(CompositionErrorKind.clipNotFound));
      final locked = withClips([generatorClip('g')], locked: true);
      expect(() => locked.setGeneratorSeed('g', 1), throwsComposition(CompositionErrorKind.trackLocked));
      expect(() => locked.setGeneratorBindings('g', bindings), throwsComposition(CompositionErrorKind.trackLocked));
      expect(() => locked.dragClipEdge('g', ClipEdge.end, s(2), sourceDuration: s(1)),
          throwsComposition(CompositionErrorKind.trackLocked));
    });

    test('setGeneratorBindings can bind and unbind the audio clock', () {
      final composition = withClips([generatorClip('g', start: s(2), sourceIn: ms(500))])
          .setAudio(AudioTrack.single(path: 'song.mp3', offset: ms(250)));
      final bound = composition.setGeneratorBindings('g', const {}, audioBound: true);
      expect(refOf(bound, 'g').audioOrigin, s(2) - ms(500) - ms(250));
      expect(refOf(bound.setGeneratorBindings('g', const {}), 'g').audioOrigin, s(2) - ms(500) - ms(250));
      expect(refOf(bound.setGeneratorBindings('g', const {}, audioBound: false), 'g').audioOrigin, isNull);
    });

    test('audioOrigin follows move, trim, split, duplicate, the audio offset and its removal', () {
      final composition = withClips([generatorClip('g', start: s(3), audioOrigin: Duration.zero)])
          .setAudio(AudioTrack.single(path: 'song.mp3', offset: ms(250)));
      expect(refOf(composition, 'g').audioOrigin, s(3) - ms(250));
      expect(audioOriginFor(composition, clipOf(composition, 'g')), s(3) - ms(250));

      final moved = composition.moveClip('g', s(5));
      expect(refOf(moved, 'g').audioOrigin, s(5) - ms(250));

      final trimmed = moved.dragClipEdge('g', ClipEdge.start, s(6), sourceDuration: s(1));
      expect(clipOf(trimmed, 'g').sourceIn, s(1));
      expect(refOf(trimmed, 'g').audioOrigin, s(5) - ms(250));

      final split = trimmed.splitClip('g', s(7), newClipId: 'g2');
      expect(refOf(split, 'g').audioOrigin, s(5) - ms(250));
      expect(refOf(split, 'g2').audioOrigin, s(5) - ms(250));

      final duplicated = split.duplicateClip('g2', newClipId: 'g3');
      expect(refOf(duplicated, 'g3').audioOrigin,
          clipOf(duplicated, 'g3').start - clipOf(duplicated, 'g3').sourceIn - ms(250));

      final shifted = moved.setAudio(AudioTrack.single(path: 'song.mp3', offset: s(1)));
      expect(refOf(shifted, 'g').audioOrigin, s(4));
      final silent = shifted.setAudio(null);
      expect(refOf(silent, 'g').audioOrigin, s(5));
      expect(reanchorGeneratorClips(silent), same(silent));
    });

    test('generators without audio keep a null audioOrigin', () {
      final composition = withClips([generatorClip('g', start: s(3))]).setAudio(AudioTrack.single(path: 'song.mp3'));
      expect(refOf(composition.moveClip('g', s(5)), 'g').audioOrigin, isNull);
      expect(refOf(composition.moveClip('g', s(5)), 'g'), generator());
    });
  });
}

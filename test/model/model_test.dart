import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  group('VisualTrack', () {
    test('sorts clips by start', () {
      final track = VisualTrack(id: 't', clips: [
        testClip('b', start: s(2), sourceOut: s(1)),
        testClip('a', sourceOut: s(1)),
      ]);
      expect(track.clips.map((clip) => clip.id), ['a', 'b']);
      expect(track.end, s(3));
    });

    test('rejects overlapping clips', () {
      expect(
        () => VisualTrack(id: 't', clips: [
          testClip('a', sourceOut: s(1)),
          testClip('b', start: ms(999), sourceOut: s(1)),
        ]),
        throwsArgumentError,
      );
    });

    test('rejects transitions that do not fit', () {
      final clips = [testClip('a', sourceOut: s(1)), testClip('b', start: s(2), sourceOut: s(1))];
      expect(
        () => VisualTrack(id: 't', clips: clips, transitions: [
          Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(100)),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('Composition', () {
    test('duration is the end of the last clip on any track', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 't1', clips: [testClip('a', sourceOut: s(2))]),
        VisualTrack(id: 't2', clips: [testClip('b', start: s(1), sourceOut: s(3))]),
      ]);
      expect(composition.duration, s(4));
      expect(composition.findClip('b')?.track.id, 't2');
      expect(composition.sources, {ref('a')});
    });

    test('rejects clip ids repeated across tracks', () {
      expect(
        () => testComposition(tracks: [
          VisualTrack(id: 't1', clips: [testClip('a', sourceOut: s(1))]),
          VisualTrack(id: 't2', clips: [testClip('a', sourceOut: s(1))]),
        ]),
        throwsArgumentError,
      );
    });

    test('accepts only 30 and 45 fps', () {
      expect(() => testComposition(framerate: Framerate.fps60), throwsArgumentError);
      expect(testComposition(framerate: Framerate.fps45).framerate, Framerate.fps45);
    });
  });

  group('OutputSpec', () {
    test('accepts sources with the same layout only', () {
      final spec = testSpec(radioPanelsCount: 2);
      expect(spec.acceptsLayoutOf(solidAnimation([], radioPanelsCount: 2).header), isTrue);
      expect(spec.acceptsLayoutOf(solidAnimation([]).header), isFalse);
      expect(spec.acceptsLayoutOf(solidAnimation([], xCount: 2, yCount: 3, radioPanelsCount: 2).header), isFalse);
    });

    test('rejects multi-pixel radio panels for version 1', () {
      expect(
        () => OutputSpec(
            xCount: 2, yCount: 2, radioPanelsCount: 1, radioPanelPixelCount: 4, version: AnimationVersion.v1),
        throwsArgumentError,
      );
    });
  });

  group('Tempo', () {
    test('nearestBeat and beatsBetween follow the grid', () {
      final tempo = Tempo(bpm: 120, firstBeatOffset: ms(100));
      expect(tempo.nearestBeat(ms(340)), ms(100));
      expect(tempo.nearestBeat(ms(360)), ms(600));
      expect(tempo.nearestBeat(Duration.zero), ms(100));
      expect(tempo.beatsBetween(Duration.zero, s(2)).toList(), [ms(100), ms(600), ms(1100), ms(1600)]);
    });

    test('rejects tempos outside the range', () {
      expect(() => Tempo(bpm: 10), throwsArgumentError);
      expect(() => Tempo(bpm: double.nan), throwsArgumentError);
    });
  });

  group('fitTransitions', () {
    final clips = [
      testClip('a', sourceOut: s(1)),
      testClip('b', start: s(1), sourceOut: ms(400)),
      testClip('c', start: ms(1400), sourceOut: s(2)),
    ];

    test('limits a transition to the shorter clip', () {
      final fitted = fitTransitions(clips, [
        Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: s(2), alignment: TransitionAlignment.endAtCut),
      ]);
      expect(fitted.kept.single.duration, ms(400));
      expect(fitted.issues.single.kind, TransitionIssueKind.clamped);
    });

    test('keeps the windows inside a clip from overlapping', () {
      final fitted = fitTransitions(clips, [
        Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(400)),
        Transition(id: 'y', fromClipId: 'b', toClipId: 'c', duration: ms(400)),
      ]);
      // b is 400 ms long; x takes its first 200 ms, y gets the remaining 200 ms before the cut.
      expect(fitted.kept.map((t) => t.duration), [ms(400), ms(400)]);
      final tight = fitTransitions(clips, [
        Transition(
            id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(400), alignment: TransitionAlignment.startAtCut),
        Transition(id: 'y', fromClipId: 'b', toClipId: 'c', duration: ms(400)),
      ]);
      expect(tight.kept.map((t) => t.duration), [ms(400)]);
      expect(tight.issues.single.kind, TransitionIssueKind.noRoom);
    });

    test('drops transitions between clips that are not adjacent', () {
      final fitted = fitTransitions(clips, [Transition(id: 'x', fromClipId: 'a', toClipId: 'c', duration: ms(100))]);
      expect(fitted.kept, isEmpty);
      expect(fitted.issues.single.kind, TransitionIssueKind.notAdjacent);
    });
  });
}

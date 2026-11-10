import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

/// Inverts the input (255 − channel) and records every call; an effect id
/// of `fail` throws `failed`, `missing` throws `unavailable`.
class RecordingHost implements EffectHost {
  final calls = <(String clipId, EffectRef ref, int frameIndex)>[];

  @override
  AnimationView apply(String clipId, EffectRef ref, int frameIndex, AnimationView input) {
    calls.add((clipId, ref, frameIndex));
    if (ref.effectId == 'fail') throw const EffectHostException(EffectHostErrorKind.failed, 'boom');
    if (ref.effectId == 'missing') throw const EffectHostException(EffectHostErrorKind.unavailable, 'none');
    Color invert(Color c) => Color.fromARGB(c.alpha, 255 - c.red, 255 - c.green, 255 - c.blue);
    return AnimationView(
      VisualFrame(duration: input.frame.duration, pixels: [for (final c in input.frame.pixels) invert(c)]),
      [
        for (final panel in input.radioPanels) RadioPanelView(panel.index, [for (final c in panel.colors) invert(c)])
      ],
    );
  }
}

EffectRef effect(String id, {Duration length = const Duration(seconds: 4), Duration? audioOrigin}) =>
    EffectRef(effectId: id, effectVersion: 1, seed: 3, length: length, audioOrigin: audioOrigin);

void main() {
  final target = testSpec(radioPanelsCount: 1, radioPanelPixelCount: 2);
  final red = solidAnimation([(Colors.red, s(4))], radioPanelsCount: 1, radioPanelPixelCount: 2);
  final sources = <SourceRef, AnimationIndex>{ref('red'): red.toIndex()};
  const cyan = Color(0xFF00FFFF);

  Clip redClip(String id) => testClip(id, source: ref('red'), sourceOut: s(4));

  Clip fx(String id, String effectId,
          {Duration start = Duration.zero,
          Duration sourceIn = Duration.zero,
          Duration? sourceOut,
          double opacity = 1,
          Region region = const Region.all(),
          BlendMode blend = BlendMode.normal}) =>
      testClip(id,
          source: effect(effectId),
          start: start,
          sourceIn: sourceIn,
          sourceOut: sourceOut ?? s(2),
          opacity: opacity,
          region: region,
          blend: blend);

  Composition stacked(List<Clip> upper, {List<Clip>? lower}) => testComposition(target: target, tracks: [
        VisualTrack(id: 't1', clips: lower ?? [redClip('a')]),
        VisualTrack(id: 't2', clips: upper),
      ]);

  group('effect clips', () {
    test('process the tracks below inside their time span and pass the input through outside it', () {
      final host = RecordingHost();
      final composition = stacked([fx('e', 'invert', start: s(1), sourceIn: ms(500), sourceOut: s(2))]);
      expect(firstPixel(Compositor.renderAt(composition, sources, ms(500), effects: host)), Colors.red);
      final processed = Compositor.renderAt(composition, sources, ms(1500), effects: host);
      expect(firstPixel(processed), cyan);
      expect(processed.radioPanels.single.colors, [cyan, cyan]);
      expect(firstPixel(Compositor.renderAt(composition, sources, ms(2600), effects: host)), Colors.red);
      // One call, at the effect frame of the source time 500 ms + 500 ms.
      expect(host.calls, [('e', effect('invert'), frameIndexAt(Framerate.fps30, s(1)))]);
    });

    test('mix the result with the input by opacity and apply only inside the region', () {
      final host = RecordingHost();
      final half = stacked([fx('e', 'invert', opacity: 0.5)]);
      final mixed = firstPixel(Compositor.renderAt(half, sources, ms(100), effects: host));
      expect(mixed.red, closeTo(128, 1));
      expect(mixed.green, closeTo(128, 1));
      expect(mixed.blue, closeTo(128, 1));

      final columns =
          stacked([fx('e', 'invert', region: Region(columns: ColumnRange(1, 1), panels: const RegionPanels.none()))]);
      final view = Compositor.renderAt(columns, sources, ms(100), effects: host);
      expect(view.frame.pixels.sublist(0, testYCount), everyElement(Colors.red));
      expect(view.frame.pixels.sublist(testYCount, 2 * testYCount), everyElement(cyan));
      expect(view.frame.pixels.sublist(2 * testYCount), everyElement(Colors.red));
      expect(view.radioPanels.single.colors, everyElement(Colors.red));
    });

    test('the layers above an effect are composited over its result', () {
      final host = RecordingHost();
      final composition = testComposition(target: target, tracks: [
        VisualTrack(id: 't1', clips: [redClip('a')]),
        VisualTrack(id: 't2', clips: [fx('e', 'invert')]),
        VisualTrack(id: 't3', clips: [
          testClip('b',
              source: ref('red'),
              sourceOut: s(4),
              region: Region(columns: ColumnRange(0, 0), panels: const RegionPanels.none()))
        ]),
      ]);
      final view = Compositor.renderAt(composition, sources, ms(100), effects: host);
      expect(view.frame.pixels.sublist(0, testYCount), everyElement(Colors.red));
      expect(view.frame.pixels.sublist(testYCount), everyElement(cyan));
    });

    test('are offline without a host and pass the input through', () {
      final composition = stacked([fx('e', 'invert')]);
      expect(firstPixel(Compositor.renderAt(composition, sources, ms(100))), Colors.red);
      expect(Compositor.offlineClips(composition, sources),
          [OfflineClip(clipId: 'e', source: effect('invert'), reason: OfflineReason.effectUnavailable)]);
      expect(Compositor.offlineClips(composition, sources, effects: RecordingHost()), isEmpty);
      final warning = Compositor.render(composition, sources).warning<OfflineSourcesWarning>()!;
      expect(warning.clips.single.reason, OfflineReason.effectUnavailable);
    });

    test('a host failure makes the clip offline for the rest of the render', () {
      final host = RecordingHost();
      final composition = stacked([fx('e', 'fail'), fx('m', 'missing', start: s(2))]);
      final result = Compositor.render(composition, sources, effects: host);
      expect(result.warnings.whereType<OfflineSourcesWarning>().single.clips, [
        OfflineClip(clipId: 'e', source: effect('fail'), reason: OfflineReason.effectFailed),
        OfflineClip(clipId: 'm', source: effect('missing'), reason: OfflineReason.effectUnavailable),
      ]);
      // Called once per clip: after the failure the clip is skipped.
      expect(host.calls.length, 2);
      expect(firstPixel(result.animation.toIndex().viewAt(ms(100))), Colors.red);
    });

    test('render asks the host for frames in timeline order with the clip source frame index', () {
      final host = RecordingHost();
      final composition = stacked([fx('e', 'invert', start: ms(100), sourceIn: ms(200), sourceOut: ms(400))]);
      Compositor.render(composition, sources, effects: host, duration: s(1));
      final indices = [for (final (_, _, index) in host.calls) index];
      expect(indices.first, frameIndexAt(Framerate.fps30, ms(200)));
      expect(indices, [for (var i = 0; i < indices.length; i++) indices.first + i]);
      // The grid frames starting inside [100 ms, 300 ms): frames 3..8.
      expect(indices.length, 6);
    });

    test('an output of another layout counts as a failure', () {
      final composition = stacked([fx('e', 'invert')]);
      final wrong = _WrongLayoutHost();
      expect(firstPixel(Compositor.renderAt(composition, sources, ms(100), effects: wrong)), Colors.red);
      final result = Compositor.render(composition, sources, effects: wrong);
      expect(result.warning<OfflineSourcesWarning>()!.clips.single.reason, OfflineReason.effectFailed);
    });
  });
}

class _WrongLayoutHost implements EffectHost {
  @override
  AnimationView apply(String clipId, EffectRef ref, int frameIndex, AnimationView input) =>
      AnimationView(VisualFrame(duration: input.frame.duration, pixels: const [Colors.white]), const []);
}

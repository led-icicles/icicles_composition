import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Matcher throwsComposition(CompositionErrorKind kind) =>
    throwsA(isA<CompositionException>().having((error) => error.kind, 'kind', kind));

Clip clipOf(Composition composition, String id) => composition.findClip(id)!.clip;

Composition twoTracks({bool topLocked = false}) => testComposition(tracks: [
      VisualTrack(id: 'low', clips: [
        testClip('a', sourceOut: s(1)),
        testClip('b', start: s(1), sourceOut: s(1)),
        testClip('c', start: s(3), sourceOut: s(1)),
      ], transitions: [
        Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(200)),
      ]),
      VisualTrack(id: 'high', locked: topLocked, clips: [testClip('d', start: s(5), sourceOut: s(1))]),
    ]);

void main() {
  group('clip flags', () {
    test('reverse, ping-pong and label are undoable props; ping-pong needs a loop', () {
      var composition = testComposition(tracks: [
        VisualTrack(
            id: 't',
            clips: [testClip('a', sourceOut: s(1)), testClip('l', start: s(2), sourceOut: s(1), loopDuration: s(3))]),
      ]);
      composition = composition.setClipReverse('a', true).setClipLabel('a', ClipLabel.red).setClipPingPong('l', true);
      expect(clipOf(composition, 'a').reverse, isTrue);
      expect(clipOf(composition, 'a').label, ClipLabel.red);
      expect(clipOf(composition, 'l').pingPong, isTrue);
      expect(() => composition.setClipPingPong('a', true), throwsComposition(CompositionErrorKind.invalidValue));
      // Turning the loop off drops the ping-pong.
      expect(clipOf(composition.setClipLoop('l', enabled: false), 'l').pingPong, isFalse);
      expect(
          () => Clip(
              id: 'p',
              source: ref('a'),
              start: Duration.zero,
              sourceIn: Duration.zero,
              sourceOut: s(1),
              pingPong: true),
          throwsArgumentError);
    });

    test('a generator clip can be reversed but never ping-pongs', () {
      final generator = GeneratorRef(generatorId: 'g', generatorVersion: 1, seed: 1, length: s(2));
      var composition = testComposition(tracks: [VisualTrack(id: 't')])
          .addClip('t', testClip('g', source: generator, sourceOut: s(2)));
      composition = composition.setClipReverse('g', true);
      expect(clipOf(composition, 'g').reverse, isTrue);
      expect(() => composition.setClipPingPong('g', true), throwsComposition(CompositionErrorKind.invalidValue));
    });
  });

  group('source time mapping', () {
    final clip = testClip('a', sourceIn: ms(100), sourceOut: ms(500));

    test('reverse mirrors the trimmed range', () {
      final reversed = clip.copyWith(reverse: true);
      expect(reversed.sourceTimeAt(Duration.zero), us(499999));
      expect(reversed.sourceTimeAt(ms(399)), us(100999));
      expect(reversed.sourceTimeAt(us(399999)), ms(100));
    });

    test('ping-pong alternates direction every pass', () {
      final looping = clip.copyWith(loopDuration: s(2), pingPong: true);
      expect(looping.sourceTimeAt(ms(100)), ms(200));
      expect(looping.sourceTimeAt(ms(400)), us(499999)); // start of the backward pass
      expect(looping.sourceTimeAt(ms(500)), us(399999));
      expect(looping.sourceTimeAt(ms(799)), us(100999));
      expect(looping.sourceTimeAt(ms(800)), ms(100)); // forward again
      expect(looping.sourceTimeAt(ms(900)), ms(200));
      final reversedFirst = looping.copyWith(reverse: true);
      expect(reversedFirst.sourceTimeAt(ms(100)), us(399999));
      expect(reversedFirst.sourceTimeAt(ms(500)), ms(200));
    });

    test('a reversed clip extended by a transition runs out of material at the other end', () {
      final reversed = clip.copyWith(reverse: true);
      // Past the end: the material before sourceIn, down to 0.
      expect(reversed.extendedSourceTimeAt(ms(450), s(1)), us(49999));
      expect(reversed.extendedSourceTimeAt(ms(900), s(1)), Duration.zero);
      // Before the start: the material after sourceOut, up to the source end.
      expect(reversed.extendedSourceTimeAt(ms(-100), s(1)), us(599999));
      expect(reversed.extendedSourceTimeAt(ms(-800), s(1)), us(999999));
    });
  });

  group('solo and loop range', () {
    test('updateTrack toggles solo and the composition reports audibility', () {
      var composition = twoTracks();
      expect(composition.hasSolo, isFalse);
      composition = composition.updateTrack('high', solo: true);
      expect(composition.hasSolo, isTrue);
      expect(composition.isTrackAudible(composition.trackById('low')!), isFalse);
      expect(composition.isTrackAudible(composition.trackById('high')!), isTrue);
      composition = composition.updateTrack('high', muted: true);
      expect(composition.isTrackAudible(composition.trackById('high')!), isFalse);
    });

    test('setLoopRange sets and clears the in/out points', () {
      var composition = twoTracks().setLoopRange(LoopRange(start: s(1), end: s(3)));
      expect(composition.loopRange, LoopRange(start: s(1), end: s(3)));
      composition = composition.setLoopRange(null);
      expect(composition.loopRange, isNull);
      expect(() => LoopRange(start: s(2), end: s(2)), throwsArgumentError);
      expect(() => LoopRange(start: ms(-1), end: s(2)), throwsArgumentError);
    });
  });

  group('markers', () {
    test('moveMarker clamps to the timeline start, updateMarker recolors', () {
      var composition = twoTracks().addMarker(Marker(id: 'm', at: s(2), label: 'Drop'));
      composition = composition.moveMarker('m', ms(-5));
      expect(composition.markerById('m')!.at, Duration.zero);
      composition = composition.updateMarker('m', color: ClipLabel.blue, at: s(1));
      expect(composition.markerById('m'), Marker(id: 'm', at: s(1), label: 'Drop', color: ClipLabel.blue));
      expect(() => composition.moveMarker('zz', s(1)), throwsComposition(CompositionErrorKind.markerNotFound));
    });
  });

  group('moveClips', () {
    test('moves the clips together and keeps the transition between them', () {
      final composition = twoTracks().moveClips(['a', 'b'], s(4));
      expect(clipOf(composition, 'a').start, s(4));
      expect(clipOf(composition, 'b').start, s(5));
      expect(clipOf(composition, 'c').start, s(3));
      expect(composition.trackById('low')!.transitions.single.id, 'x');
    });

    test('refuses an overlap with a clip that is not moved, clamps the delta at the timeline start', () {
      final composition = twoTracks();
      expect(() => composition.moveClips(['b', 'c'], s(-9)), throwsComposition(CompositionErrorKind.overlap));
      expect(() => composition.moveClips(['a'], ms(500)), throwsComposition(CompositionErrorKind.overlap));
      final clamped = composition.moveClips(['a', 'b'], s(-9));
      expect(clipOf(clamped, 'a').start, Duration.zero);
      expect(clipOf(clamped, 'b').start, s(1));
    });

    test('shifts tracks, clamped to the existing ones, and refuses locked tracks', () {
      final up = twoTracks().moveClips(['c'], s(0), trackShift: 5);
      expect(up.findClip('c')!.track.id, 'high');
      expect(() => twoTracks(topLocked: true).moveClips(['c'], s(0), trackShift: 1),
          throwsComposition(CompositionErrorKind.trackLocked));
      final down = twoTracks().moveClips(['d'], s(0), trackShift: -3);
      expect(down.findClip('d')!.track.id, 'low');
      expect(
          () => twoTracks().moveClips(['d'], s(-5), trackShift: -1), throwsComposition(CompositionErrorKind.overlap));
    });

    test('drops a transition to a clip left behind, and nudgeClips is a plain move', () {
      final composition = twoTracks().nudgeClips(['b'], s(1));
      expect(clipOf(composition, 'b').start, s(2));
      expect(composition.trackById('low')!.transitions, isEmpty);
      expect(() => twoTracks().moveClips(['zz'], s(1)), throwsComposition(CompositionErrorKind.clipNotFound));
      expect(twoTracks().moveClips([], s(1)), twoTracks());
    });
  });

  group('removeClips and rippleDelete', () {
    test('removeClips removes across tracks in one step, all or nothing', () {
      final composition = twoTracks().removeClips(['a', 'd']);
      expect(composition.findClip('a'), isNull);
      expect(composition.findClip('d'), isNull);
      expect(composition.trackById('low')!.transitions, isEmpty);
      expect(() => twoTracks(topLocked: true).removeClips(['a', 'd']),
          throwsComposition(CompositionErrorKind.trackLocked));
    });

    test('rippleDelete closes the gap on that track only', () {
      final composition = twoTracks().rippleDelete('a');
      expect(composition.findClip('a'), isNull);
      expect(clipOf(composition, 'b').start, Duration.zero);
      expect(clipOf(composition, 'c').start, s(2));
      expect(clipOf(composition, 'd').start, s(5));
      expect(composition.trackById('low')!.transitions, isEmpty);
    });

    test('rippleDelete keeps transitions between the shifted clips', () {
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          testClip('a', sourceOut: s(1)),
          testClip('b', start: s(2), sourceOut: s(1)),
          testClip('c', start: s(3), sourceOut: s(1)),
        ], transitions: [
          Transition(id: 'x', fromClipId: 'b', toClipId: 'c', duration: ms(200)),
        ]),
      ]).rippleDelete('a');
      expect(clipOf(composition, 'b').start, s(1));
      expect(clipOf(composition, 'c').start, s(2));
      expect(composition.trackById('t')!.transitions.single.id, 'x');
    });
  });

  group('pasteClips', () {
    final templates = [
      testClip('p', start: s(10), sourceOut: s(1), opacity: 0.5, label: ClipLabel.green),
      testClip('q', start: s(12), sourceOut: s(1)),
    ];

    test('pastes copies keeping the relative offsets under the new ids', () {
      final composition = twoTracks().pasteClips(templates, s(6), 'low', newClipIds: ['p2', 'q2']);
      expect(clipOf(composition, 'p2').start, s(6));
      expect(clipOf(composition, 'q2').start, s(8));
      expect(clipOf(composition, 'p2').opacity, 0.5);
      expect(clipOf(composition, 'p2').label, ClipLabel.green);
      expect(composition.findClip('p'), isNull);
    });

    test('clamps the paste point to the timeline start', () {
      final composition = testComposition(tracks: [VisualTrack(id: 't')])
          .pasteClips(templates, ms(-500), 't', newClipIds: ['p2', 'q2']);
      expect(clipOf(composition, 'p2').start, Duration.zero);
      expect(clipOf(composition, 'q2').start, s(2));
    });

    test('refuses overlaps, repeated or used ids, wrong id counts and locked tracks', () {
      final composition = twoTracks();
      expect(() => composition.pasteClips(templates, ms(500), 'low', newClipIds: ['p2', 'q2']),
          throwsComposition(CompositionErrorKind.overlap));
      expect(() => composition.pasteClips(templates, s(6), 'low', newClipIds: ['p2', 'p2']),
          throwsComposition(CompositionErrorKind.duplicateId));
      expect(() => composition.pasteClips(templates, s(6), 'low', newClipIds: ['a', 'q2']),
          throwsComposition(CompositionErrorKind.duplicateId));
      expect(() => composition.pasteClips(templates, s(6), 'low', newClipIds: ['p2']),
          throwsComposition(CompositionErrorKind.invalidValue));
      expect(() => twoTracks(topLocked: true).pasteClips(templates, s(6), 'high', newClipIds: ['p2', 'q2']),
          throwsComposition(CompositionErrorKind.trackLocked));
      final overlapping = [testClip('p', sourceOut: s(2)), testClip('q', start: s(1), sourceOut: s(1))];
      expect(() => composition.pasteClips(overlapping, s(6), 'low', newClipIds: ['p2', 'q2']),
          throwsComposition(CompositionErrorKind.overlap));
    });

    test('a pasted audio-bound generator clip is re-anchored at its new place', () {
      final generator = GeneratorRef(generatorId: 'g', generatorVersion: 1, seed: 1, length: s(2), audioOrigin: s(9));
      final template = testClip('g', source: generator, start: s(9), sourceOut: s(2));
      final composition =
          testComposition(tracks: [VisualTrack(id: 't')]).pasteClips([template], s(4), 't', newClipIds: ['g2']);
      expect((clipOf(composition, 'g2').source as GeneratorRef).audioOrigin, s(4));
    });
  });

  group('applyAttributes', () {
    final template = testClip('tpl',
        sourceOut: s(1),
        blend: BlendMode.screen,
        opacity: 0.4,
        fadeIn: ms(800),
        fadeOut: ms(900),
        region: const Region.panelsOnly(),
        isMask: true,
        label: ClipLabel.purple);

    test('copies blend, opacity, fades (clamped), region and mask onto the targets', () {
      final composition = twoTracks().applyAttributes(['a', 'd', 'tpl'], template);
      for (final id in ['a', 'd']) {
        final clip = clipOf(composition, id);
        expect(clip.blend, BlendMode.screen);
        expect(clip.opacity, 0.4);
        expect(clip.fadeIn, ms(800));
        expect(clip.fadeOut, ms(900));
        expect(clip.region, const Region.panelsOnly());
        expect(clip.isMask, isTrue);
        expect(clip.label, ClipLabel.none);
      }
      expect(clipOf(composition, 'b').blend, BlendMode.normal);
      final short = testComposition(tracks: [
        VisualTrack(id: 't', clips: [testClip('s', sourceOut: ms(500))]),
      ]).applyAttributes(['s'], template, label: true);
      expect(clipOf(short, 's').fadeIn, ms(500));
      expect(clipOf(short, 's').label, ClipLabel.purple);
    });

    test('copies the parameters and the reactivity of a same-program template', () {
      GeneratorRef rain({AudioReactivity reactivity = AudioReactivity.none, double speed = 1}) => GeneratorRef(
            generatorId: 'icicles.rain',
            generatorVersion: 1,
            seed: 7,
            length: s(4),
            bindings: {'speed': ConstantBinding(speed)},
            reactivity: reactivity,
          );
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          testClip('tpl', source: rain(reactivity: AudioReactivity.defaults, speed: 2), sourceOut: s(1)),
          testClip('g', source: rain(), start: s(2), sourceOut: s(1)),
          testClip('other',
              source: GeneratorRef(generatorId: 'icicles.snow', generatorVersion: 1, seed: 1, length: s(4)),
              start: s(4),
              sourceOut: s(1)),
        ]),
      ]);
      final template = clipOf(composition, 'tpl');
      final copied = composition.applyAttributes(['g', 'other'], template);
      final g = clipOf(copied, 'g').source as GeneratorRef;
      expect(g.reactivity, AudioReactivity.defaults);
      expect(g.bindings, {'speed': const ConstantBinding(2.0)});
      expect(g.audioOrigin, isNotNull, reason: 'follows the template\'s audio binding');
      expect((clipOf(copied, 'other').source as GeneratorRef).reactivity, AudioReactivity.none);
      final plain = composition.applyAttributes(['g'], template, params: false);
      expect((clipOf(plain, 'g').source as GeneratorRef).reactivity, AudioReactivity.none);
    });

    test('selects the attributes and refuses locked tracks as a whole', () {
      final composition = twoTracks().applyAttributes(['a'], template, blend: false, fades: false, isMask: false);
      expect(clipOf(composition, 'a').blend, BlendMode.normal);
      expect(clipOf(composition, 'a').opacity, 0.4);
      expect(clipOf(composition, 'a').fadeIn, Duration.zero);
      expect(clipOf(composition, 'a').isMask, isFalse);
      expect(() => twoTracks(topLocked: true).applyAttributes(['a', 'd'], template),
          throwsComposition(CompositionErrorKind.trackLocked));
    });

    test('copies the bindings of the same generator only, following the audio binding', () {
      GeneratorRef generator(String id, {Map<String, ParamBinding> bindings = const {}, Duration? audioOrigin}) =>
          GeneratorRef(
              generatorId: id,
              generatorVersion: 1,
              seed: 3,
              length: s(2),
              bindings: bindings,
              audioOrigin: audioOrigin);
      final bindings = {'speed': const ConstantBinding(2.0)};
      final from =
          testClip('from', source: generator('rain', bindings: bindings, audioOrigin: Duration.zero), sourceOut: s(2));
      final composition = testComposition(tracks: [
        VisualTrack(id: 't', clips: [
          testClip('same', start: s(1), source: generator('rain'), sourceOut: s(2)),
          testClip('other', start: s(4), source: generator('snow'), sourceOut: s(2)),
          testClip('file', start: s(7), sourceOut: s(1)),
        ]),
      ]).applyAttributes(['same', 'other', 'file'], from);
      final same = clipOf(composition, 'same').source as GeneratorRef;
      expect(same.bindings, bindings);
      expect(same.seed, 3);
      expect(same.audioOrigin, s(1));
      expect((clipOf(composition, 'other').source as GeneratorRef).bindings, isEmpty);
      expect(clipOf(composition, 'file').source, ref('a'));
    });
  });
}

import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Map<SourceRef, AnimationIndex> indexes(Map<String, Animation> animations) =>
    {for (final MapEntry(:key, :value) in animations.entries) ref(key): value.toIndex()};

Composition layered(List<VisualTrack> tracks, {OutputSpec? target, Framerate framerate = Framerate.fps30}) =>
    testComposition(tracks: tracks, target: target, framerate: framerate);

VisualTrack track(String id, List<Clip> clips,
        {bool muted = false, double opacity = 1, List<Transition> transitions = const []}) =>
    VisualTrack(id: id, clips: clips, muted: muted, opacity: opacity, transitions: transitions);

Color pixelAt(Composition composition, Map<SourceRef, AnimationIndex> sources, Duration time) =>
    firstPixel(Compositor.renderAt(composition, sources, time));

Color composite(Color source, int alpha, Color destination, [BlendMode mode = BlendMode.normal]) =>
    Color.composite(source.withAlpha(alpha), destination, mode);

void main() {
  final red = solidAnimation([(Colors.red, s(4))]);
  final green = solidAnimation([(Colors.green, s(4))]);
  final blue = solidAnimation([(Colors.blue, s(4))]);
  final white = solidAnimation([(Colors.white, s(4))]);
  final sources = indexes({'red': red, 'green': green, 'blue': blue, 'white': white});

  Clip solid(String id, String color,
          {Duration start = Duration.zero,
          Duration? length,
          double opacity = 1,
          BlendMode blend = BlendMode.normal,
          Duration fadeIn = Duration.zero,
          Region region = const Region.all()}) =>
      testClip(id,
          source: ref(color),
          start: start,
          sourceOut: length ?? s(2),
          opacity: opacity,
          blend: blend,
          fadeIn: fadeIn,
          region: region);

  group('compositing', () {
    test('starts from opaque black, so a half-transparent clip gives half-bright opaque colors', () {
      final composition = layered([
        track('t', [solid('a', 'white', opacity: 0.5)])
      ]);
      final pixel = pixelAt(composition, sources, ms(100));
      expect(pixel, const Color(0xFF808080));
      expect(pixel.isOpaque, isTrue);

      final decoded = Animation.fromBytes(Compositor.render(composition, sources).animation.toBytes());
      expect(firstPixel(decoded.toIndex().viewAt(ms(100))), pixel);
    });

    test('is empty (black) where no clip is active', () {
      final composition = layered([
        track('t', [solid('a', 'white', start: s(1))])
      ]);
      expect(pixelAt(composition, sources, ms(500)), Colors.black);
    });

    test('layers tracks bottom to top', () {
      final bottomRed = layered([
        track('t1', [solid('a', 'red')]),
        track('t2', [solid('b', 'green')])
      ]);
      expect(pixelAt(bottomRed, sources, ms(100)), Colors.green);
      final bottomGreen = layered([
        track('t1', [solid('b', 'green')]),
        track('t2', [solid('a', 'red')])
      ]);
      expect(pixelAt(bottomGreen, sources, ms(100)), Colors.red);
      final halfTop = layered([
        track('t1', [solid('a', 'red')]),
        track('t2', [solid('b', 'green', opacity: 0.5)])
      ]);
      expect(pixelAt(halfTop, sources, ms(100)), composite(Colors.green, 128, Colors.red));
    });

    test('uses the clip blend mode', () {
      final composition = layered([
        track('t1', [solid('a', 'red')]),
        track('t2', [solid('b', 'blue', blend: BlendMode.add)])
      ]);
      expect(pixelAt(composition, sources, ms(100)), Colors.magenta);
    });

    test('scales alpha by opacity, fade and track opacity', () {
      final fading = layered([
        track('t', [solid('a', 'white', fadeIn: s(1))])
      ]);
      expect(pixelAt(fading, sources, ms(500)), composite(Colors.white, 128, Colors.black));
      final both = layered([
        track('t', [solid('a', 'white', opacity: 0.5)], opacity: 0.5)
      ]);
      expect(pixelAt(both, sources, ms(100)), composite(Colors.white, 64, Colors.black));
    });

    test('does not draw muted tracks', () {
      final composition = layered([
        track('t1', [solid('a', 'red')]),
        track('t2', [solid('b', 'green')], muted: true)
      ]);
      expect(pixelAt(composition, sources, ms(100)), Colors.red);
    });
  });

  group('regions and radio panels', () {
    final target = testSpec(radioPanelsCount: 2, radioPanelPixelCount: 2);
    final panelSource = solidAnimation([(Colors.white, s(2))], radioPanelsCount: 2, radioPanelPixelCount: 2);
    final redBase =
        solidAnimation([(Colors.red, s(2))], radioPanelsCount: 2, radioPanelPixelCount: 2, panelColor: Colors.blue);
    final panelSources = indexes({'white': panelSource, 'red': redBase});

    test('masks icicles and radio panels', () {
      final icicles = layered([
        track('t', [solid('a', 'white', region: const Region.iciclesOnly())])
      ], target: target);
      final view = Compositor.renderAt(icicles, panelSources, ms(100));
      expect(firstPixel(view), Colors.white);
      expect(view.radioPanels.expand((panel) => panel.colors), everyElement(Colors.black));

      final panels = layered([
        track('t', [solid('a', 'white', region: const Region.panelsOnly())])
      ], target: target);
      final panelView = Compositor.renderAt(panels, panelSources, ms(100));
      expect(panelView.frame.pixels, everyElement(Colors.black));
      expect(panelView.radioPanels.expand((panel) => panel.colors), everyElement(Colors.white));
      expect(panelView.radioPanels.map((panel) => panel.index), [1, 2]);
    });

    test('masks icicle columns (column-major pixels) and chosen panels', () {
      final composition = layered([
        track('t', [
          solid('a', 'white', region: Region(columns: ColumnRange(1, 1), panels: const RegionPanels.some({2})))
        ])
      ], target: target);
      final view = Compositor.renderAt(composition, panelSources, ms(100));
      // 3 columns × 2 rows: only column 1 (indices 2, 3) is drawn.
      expect(view.frame.pixels, [Colors.black, Colors.black, Colors.white, Colors.white, Colors.black, Colors.black]);
      expect(view.radioPanels[0].colors, everyElement(Colors.black));
      expect(view.radioPanels[1].colors, everyElement(Colors.white));
    });

    test('a column range past the grid draws nothing; an empty region draws nothing', () {
      final outside = layered([
        track('t', [solid('a', 'white', region: Region(columns: ColumnRange(7, 9)))])
      ], target: target);
      final outsideView = Compositor.renderAt(outside, panelSources, ms(100));
      expect(outsideView.frame.pixels, everyElement(Colors.black));
      expect(outsideView.radioPanels.expand((panel) => panel.colors), everyElement(Colors.white));

      final empty = layered([
        track('t', [solid('a', 'white', region: const Region(icicles: false, panels: RegionPanels.none()))])
      ], target: target);
      final emptyView = Compositor.renderAt(empty, panelSources, ms(100));
      expect(emptyView.frame.pixels, everyElement(Colors.black));
      expect(emptyView.radioPanels.expand((panel) => panel.colors), everyElement(Colors.black));
    });

    test('lower layers show through the masked part of an upper clip', () {
      final composition = layered([
        track('t1', [solid('a', 'red')]),
        track('t2', [
          solid('b', 'white', region: Region(columns: ColumnRange(0, 0), panels: const RegionPanels.some({1})))
        ]),
      ], target: target);
      final view = Compositor.renderAt(composition, panelSources, ms(100));
      expect(view.frame.pixels, [Colors.white, Colors.white, Colors.red, Colors.red, Colors.red, Colors.red]);
      expect(view.radioPanels[0].colors, everyElement(Colors.white));
      expect(view.radioPanels[1].colors, everyElement(Colors.blue));
    });

    test('blends radio panels per panel and LED', () {
      final composition = layered([
        track('t1', [solid('a', 'red')]),
        track('t2', [solid('b', 'white', opacity: 0.5)]),
      ], target: target);
      final view = Compositor.renderAt(composition, panelSources, ms(100));
      expect(view.radioPanels.first.colors, everyElement(composite(Colors.white, 128, Colors.blue)));
      expect(firstPixel(view), composite(Colors.white, 128, Colors.red));
    });
  });

  group('time mapping', () {
    // Frame k of the ramp has red = k and lasts 10 ms: 100 frames = 1 s.
    final rampSources = indexes({'ramp': rampAnimation(100)});

    test('follows trim, speed and loop', () {
      final trimmed = layered([
        track('t', [testClip('a', source: ref('ramp'), start: s(1), sourceIn: ms(200), sourceOut: ms(600), speed: 2)]),
      ]);
      expect(pixelAt(trimmed, rampSources, ms(1100)).red, 40);
      final looping = layered([
        track('t', [testClip('a', source: ref('ramp'), sourceIn: ms(200), sourceOut: ms(500), loopDuration: s(2))]),
      ]);
      expect(pixelAt(looping, rampSources, ms(350)).red, 25);
      expect(pixelAt(looping, rampSources, ms(1950)).red, 35);
    });

    test('never samples past the source end (range 1 s, speed 0.1, 10 s)', () {
      final composition = layered([
        track('t', [testClip('a', source: ref('ramp'), sourceOut: s(1), speed: 0.1)])
      ]);
      expect(composition.duration, s(10));
      expect(pixelAt(composition, rampSources, s(10) - us(1)).red, 99);
      expect(() => Compositor.render(composition, rampSources), returnsNormally);
    });
  });

  group('transitions', () {
    Composition crossfade(
            {double incomingOpacity = 1, String from = 'red', Duration fromOut = const Duration(seconds: 2)}) =>
        layered([
          track(
            't',
            [
              testClip('a', source: ref(from), sourceOut: fromOut),
              testClip('b', source: ref('green'), start: fromOut, sourceOut: s(2), opacity: incomingOpacity),
            ],
            transitions: [Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: s(1))],
          ),
        ]);

    test('dissolve linearly between opaque clips around the cut', () {
      final composition = crossfade();
      expect(pixelAt(composition, sources, ms(1400)), Colors.red);
      expect(pixelAt(composition, sources, ms(1500)), Colors.red, reason: 'window start: incoming weight 0');
      expect(pixelAt(composition, sources, s(2)), composite(Colors.green, 128, Colors.red));
      expect(pixelAt(composition, sources, ms(2400)), composite(Colors.green, 230, Colors.red));
      expect(pixelAt(composition, sources, ms(2500)), Colors.green);
    });

    test('fade the outgoing clip so its visible share falls linearly under a translucent incoming clip', () {
      final composition = crossfade(incomingOpacity: 0.5);
      // p = 0.5: incoming alpha 0.25, outgoing weight 0.5 / (1 − 0.25).
      final outgoing = composite(Colors.red, (255 * 0.5 / 0.75).round(), Colors.black);
      expect(pixelAt(composition, sources, s(2)), composite(Colors.green, 64, outgoing));
    });

    test('use material after sourceOut when the source has it, else freeze the last frame', () {
      final ramps = indexes({'long': rampAnimation(150), 'short': rampAnimation(100), 'green': green});
      Color outgoingAt(String from) {
        final composition = layered([
          track(
            't',
            [
              testClip('a', source: ref(from), sourceOut: s(1)),
              testClip('b', source: ref('green'), start: s(1), sourceOut: s(1), opacity: 0),
            ],
            transitions: [Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(400))],
          ),
        ]);
        return pixelAt(composition, ramps, ms(1100));
      }

      // Incoming opacity 0: the outgoing weight is 1 − p = 0.25 at 1.1 s.
      expect(outgoingAt('long'), composite(const Color.fromRGB(110, 0, 0), 64, Colors.black));
      expect(outgoingAt('short'), composite(const Color.fromRGB(99, 0, 0), 64, Colors.black));
    });

    test('frozenTransitionParts reports the held parts', () {
      final transition = Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(400));
      final from = testClip('a', sourceOut: s(1));
      final to = testClip('b', start: s(1), sourceIn: ms(50), sourceOut: s(1));
      final parts =
          frozenTransitionParts(transition, from: from, to: to, fromSourceLength: ms(1100), toSourceLength: s(1));
      expect(parts.outgoing, ms(100));
      expect(parts.incoming, ms(150));
      final looping = frozenTransitionParts(
        transition,
        from: from.copyWith(loopDuration: s(1)),
        to: to,
        fromSourceLength: s(1),
        toSourceLength: s(1),
      );
      expect(looping.outgoing, Duration.zero);
    });
  });

  group('offline sources', () {
    final composition = layered([
      track('t1', [solid('a', 'red')]),
      track('t2', [testClip('b', source: ref('missing'), sourceOut: s(2))]),
      track('t3', [testClip('c', source: ref('wide'), sourceOut: s(2))]),
      track('t4', [testClip('d', source: ref('muted'), sourceOut: s(2))], muted: true),
    ]);
    final withWide = {
      ...sources,
      ref('wide'): solidAnimation([(Colors.white, s(2))], xCount: 2, yCount: 2).toIndex()
    };

    test('are not drawn', () {
      expect(pixelAt(composition, withWide, ms(100)), Colors.red);
    });

    test('are reported by render without blocking the export', () {
      final result = Compositor.render(composition, withWide);
      expect(result.animation.duration, s(2));
      final warning = result.warning<OfflineSourcesWarning>()!;
      expect(warning.kind, RenderWarningKind.offlineSources);
      expect(warning.clips, [
        OfflineClip(clipId: 'b', source: ref('missing'), reason: OfflineReason.missing),
        OfflineClip(clipId: 'c', source: ref('wide'), reason: OfflineReason.layoutMismatch),
      ]);
      expect(warning.message, contains('clips/missing.anim'));
    });
  });

  group('render', () {
    final rampSources = indexes({'ramp': rampAnimation(50, frameDuration: ms(20)), 'white': white});

    test('writes the target header, one loop, 24-bit colors and controller-readable frame types', () {
      final target =
          OutputSpec(xCount: testXCount, yCount: testYCount, radioPanelsCount: 1, version: AnimationVersion.v1);
      final panelRamp = indexes({'ramp': rampAnimation(50, frameDuration: ms(20), radioPanelsCount: 1)});
      final composition = layered([
        track('t', [testClip('a', source: ref('ramp'), sourceOut: s(1))])
      ], target: target);
      final animation = Compositor.render(composition, panelRamp).animation;
      expect(animation.header.loopsCount, 1);
      expect(animation.header.version, AnimationVersion.v1);
      expect(animation.header.hasSameLayout(target.toHeader(name: '')), isTrue);
      expect(animation.useRgb565, isFalse);
      expect(animation.optimize, isTrue);
      const readable = {
        FrameType.delay,
        FrameType.visual,
        FrameType.additive,
        FrameType.radioColor,
        FrameType.radioVisualFrame
      };
      expect(animation.frames.map((frame) => frame.type).toSet().difference(readable), isEmpty);
      expect(Animation.fromBytes(animation.toBytes()).toIndex().duration, animation.duration);
    });

    test('samples renderAt on the frame grid, identical after toBytes → fromBytes', () {
      final composition = layered([
        track('t1', [testClip('a', source: ref('ramp'), sourceOut: s(1), speed: 0.7, loopDuration: s(3))]),
        track('t2', [
          testClip('b', source: ref('white'), start: ms(500), sourceOut: s(2), opacity: 0.3, blend: BlendMode.screen)
        ]),
      ], framerate: Framerate.fps45);
      final result = Compositor.render(composition, rampSources);
      final decoded = Animation.fromBytes(result.animation.toBytes()).toIndex();
      final framerate = composition.framerate;
      for (var i = 0; i < frameCountFor(framerate, composition.duration); i++) {
        final time = framerate.frameStart(i);
        final expected = Compositor.renderAt(composition, rampSources, time);
        final actual = decoded.viewAt(time);
        expect(actual.frame.pixels, expected.frame.pixels, reason: 'frame $i');
        expect(actual.radioPanels, expected.radioPanels, reason: 'frame $i');
      }
    });

    test('is deterministic', () {
      final composition = layered([
        track('t', [testClip('a', source: ref('ramp'), sourceOut: s(1), speed: 1.3)])
      ]);
      expect(
        Compositor.render(composition, rampSources).animation.toBytes(),
        Compositor.render(composition, rampSources).animation.toBytes(),
      );
    });

    for (final framerate in [Framerate.fps45, Framerate.fps30]) {
      test('a 3-minute export at ${framerate.framesPerSecond} fps keeps its length through toBytes → fromBytes', () {
        final composition = layered([
          track('t', [testClip('a', source: ref('ramp'), sourceOut: s(1), loopDuration: const Duration(minutes: 3))]),
        ], framerate: framerate);
        expect(composition.duration, const Duration(minutes: 3));
        final result = Compositor.render(composition, rampSources);
        final decoded = Animation.fromBytes(result.animation.toBytes());
        expect(decoded.duration, closeToDuration(composition.duration, ms(1)));
        expect(result.warnings, isEmpty);
      });
    }

    test('warns when a static stretch over 65.5 s needs a standalone pause', () {
      final long = layered([
        track('t', [testClip('a', source: ref('white'), sourceOut: s(1), loopDuration: s(70))])
      ]);
      final result = Compositor.render(long, rampSources);
      final warning = result.warning<FirmwareDelayTruncationWarning>()!;
      expect(warning.kind, RenderWarningKind.firmwareDelayTruncation);
      expect(warning.delays.single.at, closeToDuration(ms(65535), ms(40)));
      expect(warning.delays.single.duration > FirmwareDelayTruncationWarning.controllerLimit, isTrue);
      expect(warning.message, contains('may shorten'));
      expect(Animation.fromBytes(result.animation.toBytes()).duration, s(70));

      final short = layered([
        track('t', [testClip('a', source: ref('white'), sourceOut: s(1), loopDuration: s(10))])
      ]);
      expect(Compositor.render(short, rampSources).warnings, isEmpty);
    });

    test('renders a given duration and refuses an empty composition', () {
      final composition = layered([
        track('t', [testClip('a', source: ref('ramp'), sourceOut: s(1))])
      ]);
      expect(Compositor.render(composition, rampSources, duration: s(3)).animation.duration, s(3));
      expect(
        () => Compositor.render(layered([]), rampSources),
        throwsA(isA<CompositionException>().having((e) => e.kind, 'kind', CompositionErrorKind.emptyComposition)),
      );
    });
  });

  group('generator sources', () {
    final generator = GeneratorRef(generatorId: 'icicles.rain', generatorVersion: 1, seed: 1, length: s(4));
    final composition = layered([
      track('t1', [solid('a', 'red')]),
      track('t2', [testClip('g', source: generator, start: s(1), sourceIn: ms(500), sourceOut: s(3))]),
    ]);

    test('a pre-baked index is drawn like a file', () {
      final baked = {...sources, generator: blue.toIndex()};
      expect(pixelAt(composition, baked, ms(500)), Colors.red);
      expect(pixelAt(composition, baked, ms(1500)), Colors.blue);
      expect(Compositor.offlineClips(composition, baked), isEmpty);
      final result = Compositor.render(composition, baked);
      expect(result.warnings, isEmpty);
      expect(result.animation.duration, closeToDuration(s(3) + ms(500), ms(40)));
    });

    test('an absent bake is a missing source', () {
      expect(pixelAt(composition, sources, ms(2500)), Colors.black);
      expect(Compositor.offlineClips(composition, sources),
          [OfflineClip(clipId: 'g', source: generator, reason: OfflineReason.missing)]);
      final warning = Compositor.render(composition, sources).warning<OfflineSourcesWarning>()!;
      expect(warning.message, contains('icicles.rain'));
    });

    test('a bake at another layout is a layout mismatch', () {
      final wide = {
        ...sources,
        generator: solidAnimation([(Colors.white, s(4))], xCount: 2, yCount: 2).toIndex()
      };
      expect(Compositor.offlineClips(composition, wide).single.reason, OfflineReason.layoutMismatch);
    });
  });

  group('pixel masks', () {
    final target = testSpec(radioPanelsCount: 2, radioPanelPixelCount: 2);
    final panelSource = solidAnimation([(Colors.white, s(2))], radioPanelsCount: 2, radioPanelPixelCount: 2);
    final redBase =
        solidAnimation([(Colors.red, s(2))], radioPanelsCount: 2, radioPanelPixelCount: 2, panelColor: Colors.blue);
    final panelSources = indexes({'white': panelSource, 'red': redBase});

    test('masks single icicle and panel pixels', () {
      final mask = PixelMask.full(target).withPixel(1, false).withPixel(4, false).withPanelPixel(2, 1, false);
      final composition = layered([
        track('t1', [solid('a', 'red')]),
        track('t2', [solid('b', 'white', region: Region(pixels: mask))]),
      ], target: target);
      final view = Compositor.renderAt(composition, panelSources, ms(100));
      expect(view.frame.pixels, [Colors.white, Colors.red, Colors.white, Colors.white, Colors.red, Colors.white]);
      expect(view.radioPanels[0].colors, [Colors.white, Colors.white]);
      expect(view.radioPanels[1].colors, [Colors.white, Colors.blue]);
    });

    test('intersects the mask with columns and panels', () {
      final mask = PixelMask.full(target).withPixel(2, false).withPanelPixel(1, 0, false);
      final composition = layered([
        track('t', [
          solid('a', 'white',
              region: Region(columns: ColumnRange(1, 1), panels: const RegionPanels.some({1}), pixels: mask))
        ]),
      ], target: target);
      final view = Compositor.renderAt(composition, panelSources, ms(100));
      expect(view.frame.pixels, [Colors.black, Colors.black, Colors.black, Colors.white, Colors.black, Colors.black]);
      expect(view.radioPanels[0].colors, [Colors.black, Colors.white]);
      expect(view.radioPanels[1].colors, everyElement(Colors.black));
    });
  });

  group('mask layers', () {
    final target = testSpec(radioPanelsCount: 1, radioPanelPixelCount: 2);
    final white = solidAnimation([(Colors.white, s(2))], radioPanelsCount: 1, radioPanelPixelCount: 2);
    final red = solidAnimation([(Colors.red, s(2))], radioPanelsCount: 1, radioPanelPixelCount: 2);
    final gray = solidAnimation([(const Color(0xFF808080), s(2))], radioPanelsCount: 1, radioPanelPixelCount: 2);
    // A left-to-right ramp: column x is white × x / 2 (3 columns).
    final gradient = Animation('g',
        xCount: testXCount,
        yCount: testYCount,
        optimize: false,
        framerate: Framerate.unlimited,
        radioPanelsCount: 1,
        radioPanelPixelCount: 2)
      ..addFrame(RadioVisualFrame(duration: Duration.zero, index: 1, colors: [Colors.black, Colors.white]))
      ..addFrame(VisualFrame(duration: s(2), pixels: [
        for (var x = 0; x < testXCount; x++)
          for (var y = 0; y < testYCount; y++)
            x == 0 ? Colors.black : (x == 1 ? const Color(0xFF808080) : Colors.white),
      ]));
    final sources = indexes({'white': white, 'red': red, 'gray': gray, 'gradient': gradient});

    test('a mask clip is not drawn and dims the tracks below by its luminance', () {
      final composition = layered([
        track('t1', [solid('a', 'white')]),
        track('t2', [testClip('m', source: ref('gradient'), sourceOut: s(2), isMask: true)]),
      ], target: target);
      final view = Compositor.renderAt(composition, sources, ms(100));
      final mid = const Color(0xFF808080).computeLuminance();
      final dimmed = (255 * mid).round();
      expect(view.frame.pixels, [
        Colors.black,
        Colors.black,
        Color.fromRGB(dimmed, dimmed, dimmed),
        Color.fromRGB(dimmed, dimmed, dimmed),
        Colors.white,
        Colors.white,
      ]);
      expect(view.radioPanels.single.colors, [Colors.black, Colors.white]);
      expect(dimmed, lessThan(128), reason: 'luminance is linear (sRGB linearized), not the gray level');
    });

    test('a mask alone shows nothing and leaves the tracks above unaffected', () {
      final alone = layered([
        track('t', [testClip('m', source: ref('white'), sourceOut: s(2), isMask: true)]),
      ], target: target);
      expect(Compositor.renderAt(alone, sources, ms(100)).frame.pixels, everyElement(Colors.black));

      final composition = layered([
        track('t1', [solid('a', 'white')]),
        track('t2', [testClip('m', source: ref('gray'), sourceOut: s(2), isMask: true)]),
        track('t3', [solid('b', 'red')]),
      ], target: target);
      expect(Compositor.renderAt(composition, sources, ms(100)).frame.pixels, everyElement(Colors.red));
    });

    test('the mask opacity, fades and region count: outside the region the lower tracks stay untouched', () {
      final half = layered([
        track('t1', [solid('a', 'white')]),
        track('t2', [testClip('m', source: ref('white'), sourceOut: s(2), isMask: true, opacity: 0.5)]),
      ], target: target);
      final halfLuminance = const Color(0xFF808080).computeLuminance();
      final expected = (255 * halfLuminance).round();
      expect(pixelAt(half, sources, ms(100)), Color.fromRGB(expected, expected, expected));

      final partial = layered([
        track('t1', [solid('a', 'white')]),
        track('t2', [
          testClip('m',
              source: ref('gray'),
              sourceOut: s(2),
              isMask: true,
              region: Region(columns: ColumnRange(0, 0), panels: const RegionPanels.none()))
        ]),
      ], target: target);
      final view = Compositor.renderAt(partial, sources, ms(100));
      final dimmed = (255 * const Color(0xFF808080).computeLuminance()).round();
      expect(view.frame.pixels.sublist(0, 2), everyElement(Color.fromRGB(dimmed, dimmed, dimmed)));
      expect(view.frame.pixels.sublist(2), everyElement(Colors.white));
      expect(view.radioPanels.single.colors, everyElement(Colors.white));

      final faded = layered([
        track('t1', [solid('a', 'white')]),
        track('t2', [testClip('m', source: ref('white'), sourceOut: s(2), isMask: true, fadeIn: s(1))]),
      ], target: target);
      // At 500 ms the mask is at alpha 0.5 → gray 128 → dimmed.
      expect(pixelAt(faded, sources, ms(500)), Color.fromRGB(dimmed, dimmed, dimmed));
      expect(pixelAt(faded, sources, ms(1500)), Colors.white);
    });

    test('a mask on the same track as normal clips applies per clip', () {
      final composition = layered([
        track('t1', [solid('a', 'white', length: s(2))]),
        track('t2', [
          solid('b', 'red', length: s(1)),
          testClip('m', source: ref('gray'), start: s(1), sourceOut: s(1), isMask: true),
        ]),
      ], target: target);
      expect(pixelAt(composition, sources, ms(500)), Colors.red);
      final dimmed = (255 * const Color(0xFF808080).computeLuminance()).round();
      expect(pixelAt(composition, sources, ms(1500)), Color.fromRGB(dimmed, dimmed, dimmed));
    });
  });
}

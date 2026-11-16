import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

const xCount = 4;
const yCount = 4;
const panelsCount = 2;
const panelPixels = 2;

final spec =
    OutputSpec(xCount: xCount, yCount: yCount, radioPanelsCount: panelsCount, radioPanelPixelCount: panelPixels);

/// One frame of 4 s whose icicle pixels are `colorOf(pixelIndex)` and whose
/// panels show [panel].
Animation pixelAnimation(Color Function(int index) colorOf, Color panel) {
  final animation = Animation(
    'test',
    xCount: xCount,
    yCount: yCount,
    optimize: false,
    framerate: Framerate.unlimited,
    radioPanelsCount: panelsCount,
    radioPanelPixelCount: panelPixels,
  );
  for (var index = 1; index <= panelsCount; index++) {
    animation
        .addFrame(RadioVisualFrame(duration: Duration.zero, index: index, colors: List.filled(panelPixels, panel)));
  }
  animation.addFrame(VisualFrame(duration: s(4), pixels: [for (var i = 0; i < xCount * yCount; i++) colorOf(i)]));
  return animation;
}

final sources = {
  ref('red'): pixelAnimation((_) => Colors.red, Colors.red).toIndex(),
  ref('green'): pixelAnimation((_) => Colors.green, Colors.green).toIndex(),
  // Pixel i of `from` is red i, of `to` green i, so a shift is visible.
  ref('from'): pixelAnimation((i) => Color.fromRGB(i + 1, 0, 0), Colors.red).toIndex(),
  ref('to'): pixelAnimation((i) => Color.fromRGB(0, i + 1, 0), Colors.green).toIndex(),
};

/// `a` (2 s) then `b` with a centered 1 s transition: window 1.5 s … 2.5 s,
/// progress 0.5 at the cut.
Composition withTransition(TransitionKind kind, TransitionDirection direction,
        {String from = 'red', String to = 'green'}) =>
    testComposition(target: spec, tracks: [
      VisualTrack(
        id: 't',
        clips: [
          testClip('a', source: ref(from), sourceOut: s(2)),
          testClip('b', source: ref(to), start: s(2), sourceOut: s(2)),
        ],
        transitions: [
          Transition(id: 'x', fromClipId: 'a', toClipId: 'b', duration: s(1), kind: kind, direction: direction),
        ],
      ),
    ]);

AnimationView viewAt(Composition composition, Duration time) => Compositor.renderAt(composition, sources, time);

Color pixel(AnimationView view, int x, int y) => view.frame.pixels[x * yCount + y];

List<Color> panelColors(AnimationView view) => [for (final panel in view.radioPanels) ...panel.colors];

final half = Color.composite(Colors.green.withAlpha(128), Colors.red, BlendMode.normal);

void main() {
  group('wipe', () {
    for (final direction in TransitionDirection.values) {
      test('${direction.name} shows the outgoing clip at p = 0 and the incoming one at p = 1', () {
        final composition = withTransition(TransitionKind.wipe, direction);
        final start = viewAt(composition, ms(1500));
        expect(start.frame.pixels, everyElement(Colors.red));
        expect(panelColors(start), everyElement(Colors.red));
        final almostEnd = viewAt(composition, ms(2500) - us(1));
        expect(almostEnd.frame.pixels, everyElement(Colors.green));
        expect(panelColors(almostEnd), everyElement(Colors.green));
      });
    }

    // At p = 0.5 the edge is at 0.575 with a soft part of 0.15: positions
    // ≤ 0.425 are fully incoming, ≥ 0.575 fully outgoing.
    List<List<Color>> columns(AnimationView view) => [
          for (var x = 0; x < xCount; x++) [for (var y = 0; y < yCount; y++) pixel(view, x, y)]
        ];

    test('left at p = 0.5 covers the left half, panel 1 switched, panel 2 not', () {
      final view = viewAt(withTransition(TransitionKind.wipe, TransitionDirection.left), s(2));
      expect(columns(view).map((column) => column.toSet()), [
        {Colors.green},
        {Colors.green},
        {Colors.red},
        {Colors.red},
      ]);
      expect(view.radioPanels[0].colors, everyElement(Colors.green));
      expect(view.radioPanels[1].colors, everyElement(Colors.red));
    });

    test('right at p = 0.5 covers the right half', () {
      final view = viewAt(withTransition(TransitionKind.wipe, TransitionDirection.right), s(2));
      expect(columns(view).map((column) => column.toSet()), [
        {Colors.red},
        {Colors.red},
        {Colors.green},
        {Colors.green},
      ]);
      expect(view.radioPanels[0].colors, everyElement(Colors.red));
      expect(view.radioPanels[1].colors, everyElement(Colors.green));
    });

    test('up at p = 0.5 covers the top LEDs, panels crossfade', () {
      final view = viewAt(withTransition(TransitionKind.wipe, TransitionDirection.up), s(2));
      expect(columns(view), everyElement([Colors.green, Colors.green, Colors.red, Colors.red]));
      expect(panelColors(view), everyElement(half));
    });

    test('down at p = 0.5 covers the bottom LEDs', () {
      final view = viewAt(withTransition(TransitionKind.wipe, TransitionDirection.down), s(2));
      expect(columns(view), everyElement([Colors.red, Colors.red, Colors.green, Colors.green]));
      expect(panelColors(view), everyElement(half));
    });

    test('center at p = 0.5 covers the middle icicles, panels half way', () {
      final view = viewAt(withTransition(TransitionKind.wipe, TransitionDirection.center), s(2));
      expect(columns(view).map((column) => column.toSet()), [
        {Colors.red},
        {Colors.green},
        {Colors.green},
        {Colors.red},
      ]);
      // Panels at u = 0.5: weight (0.575 − 0.5) / 0.15 ≈ 0.5.
      for (final color in panelColors(view)) {
        expect(color.red, inInclusiveRange(127, 128));
        expect(color.green, inInclusiveRange(127, 128));
      }
    });

    test('has a soft edge', () {
      // p = 0.75 (2.25 s), left: edge 0.8625; icicle 3 at u = 0.875 is just
      // outside, icicle 2 (0.625) fully in. At 2.26 s the edge passes 0.875.
      final composition = withTransition(TransitionKind.wipe, TransitionDirection.left);
      expect(pixel(viewAt(composition, ms(2250)), 3, 0), Colors.red);
      final soft = pixel(viewAt(composition, ms(2300)), 3, 0);
      expect(soft, isNot(anyOf(Colors.red, Colors.green)));
      expect(soft.green, greaterThan(0));
      expect(soft.red, greaterThan(0));
    });
  });

  group('dip', () {
    test('to black is all black at the midpoint', () {
      final view = viewAt(withTransition(TransitionKind.dipToBlack, TransitionDirection.left), s(2));
      expect(view.frame.pixels, everyElement(Colors.black));
      expect(panelColors(view), everyElement(Colors.black));
    });

    test('to white is all white at the midpoint', () {
      final view = viewAt(withTransition(TransitionKind.dipToWhite, TransitionDirection.left), s(2));
      expect(view.frame.pixels, everyElement(Colors.white));
      expect(panelColors(view), everyElement(Colors.white));
    });

    test('fades the outgoing clip in the first half and the incoming one in the second', () {
      final composition = withTransition(TransitionKind.dipToBlack, TransitionDirection.left);
      expect(viewAt(composition, ms(1500)).frame.pixels, everyElement(Colors.red));
      // p = 0.25: red mixed toward black by 0.5.
      expect(viewAt(composition, ms(1750)).frame.pixels,
          everyElement(Color.alphaBlend(Colors.black.withAlpha(128), Colors.red)));
      // p = 0.75: green mixed toward black by 0.5.
      expect(viewAt(composition, ms(2250)).frame.pixels,
          everyElement(Color.alphaBlend(Colors.black.withAlpha(128), Colors.green)));
      expect(viewAt(composition, ms(2500)).frame.pixels, everyElement(Colors.green));
    });
  });

  group('push', () {
    Color from(int x, int y) => Color.fromRGB(x * yCount + y + 1, 0, 0);
    Color to(int x, int y) => Color.fromRGB(0, x * yCount + y + 1, 0);
    AnimationView pushAt(TransitionDirection direction, Duration time) =>
        viewAt(withTransition(TransitionKind.push, direction, from: 'from', to: 'to'), time);

    test('left at p = 0.5 shifts by half the icicles, the incoming clip entering from the left', () {
      final view = pushAt(TransitionDirection.left, s(2));
      for (var y = 0; y < yCount; y++) {
        expect([for (var x = 0; x < xCount; x++) pixel(view, x, y)], [to(2, y), to(3, y), from(0, y), from(1, y)]);
      }
      expect(panelColors(view), everyElement(half));
    });

    test('center pushes like left', () {
      expect(pushAt(TransitionDirection.center, s(2)), pushAt(TransitionDirection.left, s(2)));
    });

    test('right at p = 0.5 shifts the other way', () {
      final view = pushAt(TransitionDirection.right, s(2));
      for (var y = 0; y < yCount; y++) {
        expect([for (var x = 0; x < xCount; x++) pixel(view, x, y)], [from(2, y), from(3, y), to(0, y), to(1, y)]);
      }
    });

    test('up and down shift along the LEDs', () {
      final up = pushAt(TransitionDirection.up, s(2));
      final down = pushAt(TransitionDirection.down, s(2));
      for (var x = 0; x < xCount; x++) {
        expect([for (var y = 0; y < yCount; y++) pixel(up, x, y)], [to(x, 2), to(x, 3), from(x, 0), from(x, 1)]);
        expect([for (var y = 0; y < yCount; y++) pixel(down, x, y)], [from(x, 2), from(x, 3), to(x, 0), to(x, 1)]);
      }
      expect(panelColors(up), everyElement(half));
    });

    test('shifts by whole icicles: one at p = 0.25', () {
      final view = pushAt(TransitionDirection.left, ms(1750));
      expect([for (var x = 0; x < xCount; x++) pixel(view, x, 0)], [to(3, 0), from(0, 0), from(1, 0), from(2, 0)]);
      expect(pushAt(TransitionDirection.left, ms(1500)).frame.pixels, [
        for (var x = 0; x < xCount; x++)
          for (var y = 0; y < yCount; y++) from(x, y)
      ]);
    });
  });

  test('a crossfade renders as before', () {
    final view = viewAt(withTransition(TransitionKind.crossfade, TransitionDirection.left), s(2));
    expect(view.frame.pixels, everyElement(half));
  });
}

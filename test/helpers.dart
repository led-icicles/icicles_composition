import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

const testXCount = 3;
const testYCount = 2;

Duration ms(int value) => Duration(milliseconds: value);
Duration us(int value) => Duration(microseconds: value);
Duration s(num value) => Duration(microseconds: (value * Duration.microsecondsPerSecond).round());

/// Matches a duration within [tolerance] (1 µs by default) of [expected].
Matcher closeToDuration(Duration expected, [Duration tolerance = const Duration(microseconds: 1)]) =>
    predicate<Duration>(
      (actual) => (actual - expected).abs() <= tolerance,
      'within ${tolerance.inMicroseconds} µs of $expected',
    );

OutputSpec testSpec({int radioPanelsCount = 0, int radioPanelPixelCount = 1}) => OutputSpec(
      xCount: testXCount,
      yCount: testYCount,
      radioPanelsCount: radioPanelsCount,
      radioPanelPixelCount: radioPanelPixelCount,
    );

AnimationFileRef ref(String name) => AnimationFileRef(path: 'clips/$name.anim', contentHash: 'hash-$name');

/// An animation of [frames] whole-grid colors, each lasting its duration;
/// radio panels show [panelColor] (default: the frame color).
Animation solidAnimation(
  List<(Color, Duration)> frames, {
  int xCount = testXCount,
  int yCount = testYCount,
  int radioPanelsCount = 0,
  int radioPanelPixelCount = 1,
  Color? panelColor,
}) {
  final animation = Animation(
    'test',
    xCount: xCount,
    yCount: yCount,
    optimize: false,
    framerate: Framerate.unlimited,
    radioPanelsCount: radioPanelsCount,
    radioPanelPixelCount: radioPanelPixelCount,
  );
  for (final (color, duration) in frames) {
    for (var panel = 1; panel <= radioPanelsCount; panel++) {
      animation.addFrame(RadioVisualFrame(
        duration: Duration.zero,
        index: panel,
        colors: List.filled(radioPanelPixelCount, panelColor ?? color),
      ));
    }
    animation.addFrame(VisualFrame.filled(duration, xCount * yCount, color));
  }
  return animation;
}

/// [count] frames of [frameDuration] where frame `k` has red = `k`, so the
/// shown frame identifies the sampled source time.
Animation rampAnimation(int count,
        {Duration frameDuration = const Duration(milliseconds: 10), int radioPanelsCount = 0}) =>
    solidAnimation(
      [for (var k = 0; k < count; k++) (Color.fromRGB(k, 0, 0), frameDuration)],
      radioPanelsCount: radioPanelsCount,
    );

Clip testClip(
  String id, {
  SourceRef? source,
  Duration start = Duration.zero,
  Duration sourceIn = Duration.zero,
  required Duration sourceOut,
  double speed = 1.0,
  Duration? loopDuration,
  BlendMode blend = BlendMode.normal,
  double opacity = 1.0,
  Duration fadeIn = Duration.zero,
  Duration fadeOut = Duration.zero,
  Region region = const Region.all(),
  bool isMask = false,
  bool reverse = false,
  bool pingPong = false,
  ClipLabel label = ClipLabel.none,
}) =>
    Clip(
      id: id,
      source: source ?? ref('a'),
      start: start,
      sourceIn: sourceIn,
      sourceOut: sourceOut,
      speed: speed,
      loopDuration: loopDuration,
      blend: blend,
      opacity: opacity,
      fadeIn: fadeIn,
      fadeOut: fadeOut,
      region: region,
      isMask: isMask,
      reverse: reverse,
      pingPong: pingPong,
      label: label,
    );

Composition testComposition({
  List<VisualTrack> tracks = const [],
  OutputSpec? target,
  Framerate framerate = Framerate.fps30,
}) =>
    Composition(name: 'test', target: target ?? testSpec(), framerate: framerate, tracks: tracks);

/// The colors of the first pixel and of every radio panel's first LED.
Color firstPixel(AnimationView view) => view.frame.pixels.first;

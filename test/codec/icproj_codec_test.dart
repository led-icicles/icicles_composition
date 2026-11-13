import 'dart:convert';
import 'dart:io';

import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_composition/icicles_composition.dart';
import 'package:icicles_generators/icicles_generators.dart';
import 'package:test/test.dart';

import '../helpers.dart';

Matcher throwsIcproj(IcprojErrorKind kind) =>
    throwsA(isA<IcprojException>().having((error) => error.kind, 'kind', kind));

Composition fullComposition() => Composition(
      name: 'Show',
      target: testSpec(radioPanelsCount: 2, radioPanelPixelCount: 3),
      framerate: Framerate.fps45,
      tracks: [
        VisualTrack(
          id: 'base',
          name: 'Base',
          opacity: 0.8,
          clips: [
            testClip('a', sourceOut: s(2), fadeIn: ms(100)),
            testClip('b',
                source: ref('b'),
                start: s(2),
                sourceIn: ms(250),
                sourceOut: us(1234567),
                speed: 0.75,
                loopDuration: s(5),
                blend: BlendMode.screen,
                opacity: 0.5,
                fadeOut: ms(300),
                region: const Region.panelsOnly()),
          ],
          transitions: [
            Transition(
                id: 'x', fromClipId: 'a', toClipId: 'b', duration: ms(500), alignment: TransitionAlignment.endAtCut),
          ],
        ),
        VisualTrack(id: 'top', name: 'Top', muted: true, locked: true, clips: [
          testClip('c',
              source: ref('c'),
              start: s(1),
              sourceOut: s(1),
              blend: BlendMode.multiply,
              region: const Region.iciclesOnly()),
        ]),
      ],
      audio: AudioTrack.single(path: '../music/song.mp3', gain: 0.9, offset: ms(-120)),
      tempo: Tempo(bpm: 127.5, firstBeatOffset: ms(80)),
      markers: [Marker(id: 'm1', at: s(3), label: 'Drop')],
    );

Map<String, Object?> jsonOf(Composition composition) =>
    jsonDecode(IcprojCodec.encode(composition)) as Map<String, Object?>;

Map<String, Object?> firstTrack(Map<String, Object?> json) =>
    (json['tracks']! as List<Object?>).first! as Map<String, Object?>;

List<Object?> clipsOf(Map<String, Object?> track) => track['clips']! as List<Object?>;

void main() {
  test('round-trips a composition', () {
    final composition = fullComposition();
    final result = IcprojCodec.decode(IcprojCodec.encode(composition));
    expect(result.problems, isEmpty);
    expect(result.composition, composition);
  });

  test('encodes stably with sorted keys and relative paths as given', () {
    final encoded = IcprojCodec.encode(fullComposition());
    expect(IcprojCodec.encode(IcprojCodec.decode(encoded).composition), encoded);
    expect(encoded, startsWith('{\n  "audio": {'));
    expect(encoded, endsWith('}\n'));
    final json = jsonOf(fullComposition());
    expect(json.keys.toList(), [...json.keys]..sort());
    expect((json['format'], json['version']), ('icproj', 1));
    expect((json['audio']! as Map<String, Object?>)['path'], '../music/song.mp3');
    final clip = clipsOf(firstTrack(json)).first! as Map<String, Object?>;
    expect(clip['source'], {'contentHash': 'hash-a', 'path': 'clips/a.anim'});
    expect(clip.containsKey('loopDurationUs'), isFalse);
  });

  group('refuses', () {
    test('invalid JSON', () {
      expect(() => IcprojCodec.decode('{nope'), throwsIcproj(IcprojErrorKind.invalidJson));
      expect(() => IcprojCodec.decode('[]'), throwsIcproj(IcprojErrorKind.invalidJson));
    });

    test('other formats', () {
      expect(() => IcprojCodec.decode('{"format": "anim", "version": 1}'), throwsIcproj(IcprojErrorKind.notIcproj));
    });

    test('unknown versions', () {
      final json = jsonOf(fullComposition())..['version'] = 3;
      expect(() => IcprojCodec.fromJson(json), throwsIcproj(IcprojErrorKind.unsupportedVersion));
      json['version'] = 0;
      expect(() => IcprojCodec.fromJson(json), throwsIcproj(IcprojErrorKind.unsupportedVersion));
      json['version'] = '1';
      expect(() => IcprojCodec.fromJson(json), throwsIcproj(IcprojErrorKind.invalidProject));
    });

    test('a missing or invalid target', () {
      final json = jsonOf(fullComposition())..remove('target');
      expect(() => IcprojCodec.fromJson(json), throwsIcproj(IcprojErrorKind.invalidProject));
      json['target'] = {
        'xCount': 0,
        'yCount': 2,
        'radioPanelsCount': 0,
        'radioPanelPixelCount': 1,
        'animationVersion': 2
      };
      expect(() => IcprojCodec.fromJson(json), throwsIcproj(IcprojErrorKind.invalidProject));
    });
  });

  group('salvages', () {
    test('drops an invalid clip and keeps the others', () {
      final json = jsonOf(fullComposition());
      final clips = clipsOf(firstTrack(json));
      (clips.first! as Map<String, Object?>).remove('source');
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.findClip('a'), isNull);
      expect(result.composition.findClip('b'), isNotNull);
      expect(result.problems.map((problem) => problem.kind), contains(IcprojProblemKind.droppedClip));
      expect(result.problems.first.path, r'$.tracks[0].clips[0]');
      // The transition lost its clip.
      expect(result.composition.trackById('base')!.transitions, isEmpty);
      expect(result.problems.map((problem) => problem.kind), contains(IcprojProblemKind.droppedTransition));
    });

    test('clamps numbers to their ranges', () {
      final json = jsonOf(fullComposition());
      final track = firstTrack(json)..['opacity'] = 7;
      final clip = clipsOf(track).first! as Map<String, Object?>;
      clip['speed'] = 50;
      clip['opacity'] = -1;
      clip['fadeInUs'] = -5;
      (json['tempo']! as Map<String, Object?>)['bpm'] = 1000;
      json['framerate'] = 44;
      final result = IcprojCodec.fromJson(json);
      final decoded = result.composition.findClip('a')!.clip;
      expect((decoded.speed, decoded.opacity, decoded.fadeIn), (Clip.maxSpeed, 0.0, Duration.zero));
      expect(result.composition.trackById('base')!.opacity, 1.0);
      expect(result.composition.tempo!.bpm, Tempo.maxBpm);
      expect(result.composition.framerate, Framerate.fps45);
      expect(result.problems.where((problem) => problem.kind == IcprojProblemKind.clampedValue), hasLength(6));
      expect(result.problems.map((problem) => problem.path), contains(r'$.tracks[0].clips[0].speed'));
    });

    test('defaults unknown enum values and ignores unknown fields', () {
      final json = jsonOf(fullComposition())..['futureField'] = {'x': 1};
      final clip = clipsOf(firstTrack(json)).first! as Map<String, Object?>;
      clip['blend'] = 'overlay';
      clip['region'] = 7;
      clip['futureField'] = true;
      final result = IcprojCodec.fromJson(json);
      final decoded = result.composition.findClip('a')!.clip;
      expect((decoded.blend, decoded.region), (BlendMode.normal, const Region.all()));
      expect(result.problems.map((problem) => problem.kind),
          [IcprojProblemKind.defaultedValue, IcprojProblemKind.defaultedValue]);
    });

    test('drops a clip overlapping an earlier one and repeated ids', () {
      final json = jsonOf(fullComposition());
      final clips = clipsOf(firstTrack(json));
      clips.add({...clips.first! as Map<String, Object?>, 'id': 'late', 'startUs': 1000000});
      clips.add({...clips.first! as Map<String, Object?>, 'startUs': 9000000});
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.findClip('late'), isNull);
      expect(result.composition.trackById('base')!.clips.map((clip) => clip.id), ['a', 'b']);
      expect(result.problems.where((problem) => problem.kind == IcprojProblemKind.droppedClip), hasLength(2));
    });

    test('shortens a transition longer than its clips', () {
      final json = jsonOf(fullComposition());
      final transition = (firstTrack(json)['transitions']! as List<Object?>).first! as Map<String, Object?>;
      transition['durationUs'] = 60000000;
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.trackById('base')!.transitions.single.duration, s(2));
      expect(result.problems.single.kind, IcprojProblemKind.clampedValue);
    });

    test('drops invalid tracks, markers, audio and tempo', () {
      final json = jsonOf(fullComposition());
      (json['tracks']! as List<Object?>).add('not a track');
      (json['tracks']! as List<Object?>).add({'id': 'base'});
      (json['markers']! as List<Object?>).add({'id': 'm2'});
      json['audio'] = {'gain': 1};
      json['tempo'] = {'bpm': 'fast'};
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.tracks, hasLength(2));
      expect(result.composition.markers, hasLength(1));
      expect(result.composition.audio, isNull);
      expect(result.composition.tempo, isNull);
      expect(result.problems.map((problem) => problem.kind), [
        IcprojProblemKind.droppedTrack,
        IcprojProblemKind.droppedTrack,
        IcprojProblemKind.droppedMarker,
        IcprojProblemKind.droppedAudio,
        IcprojProblemKind.droppedTempo,
      ]);
    });
  });

  group('generator sources', () {
    GeneratorRef generatorRef({Duration? audioOrigin, Map<String, ParamBinding>? bindings}) => GeneratorRef(
          generatorId: 'icicles.rain',
          generatorVersion: 3,
          seed: 42,
          length: s(4),
          audioOrigin: audioOrigin,
          bindings: bindings ??
              {
                'speed': const ConstantBinding(1.5),
                'count': const ConstantBinding(12),
                'mirror': const ConstantBinding(true),
                'mode': const ConstantBinding('fall'),
                'color': const ConstantBinding(Color(0xFFFF8800)),
                'level': const AudioBinding(feature: AudioFeatureKey.bass, min: 0.2, max: 1),
                'pulse': const BeatBinding(shape: BeatShape.pulse, periodBeats: 2, min: 0, max: 1),
                'fade': const RampBinding(from: 1, to: 0, curve: RampCurve.sinOut),
              },
        );

    Composition withGenerator({Duration? audioOrigin}) => Composition(
          name: 'Gen',
          target: testSpec(),
          tracks: [
            VisualTrack(id: 't', clips: [
              testClip('f', sourceOut: s(1)),
              testClip('g',
                  source: generatorRef(audioOrigin: audioOrigin), start: s(1), sourceIn: ms(500), sourceOut: s(3)),
            ]),
          ],
          audio: AudioTrack.single(path: 'song.mp3', offset: ms(250)),
        );

    test('are written as version 2 with typed sources and round-trip', () {
      final composition = withGenerator(audioOrigin: ms(250));
      final json = jsonOf(composition);
      expect(json['version'], 2);
      final clips = clipsOf(firstTrack(json));
      expect((clips[0]! as Map<String, Object?>)['source'],
          {'type': 'file', 'path': 'clips/a.anim', 'contentHash': 'hash-a'});
      final generator = (clips[1]! as Map<String, Object?>)['source']! as Map<String, Object?>;
      expect(generator['type'], 'generator');
      expect(generator['id'], 'icicles.rain');
      expect(generator['version'], 3);
      expect(generator['seed'], 42);
      expect(generator['lengthUs'], 4000000);
      expect(generator['audioOriginUs'], 250000);
      expect((generator['params']! as Map<String, Object?>)['level'], {
        'type': 'audio',
        'feature': 'bass',
        'min': 0.2,
        'max': 1,
        'attackMs': 10,
        'releaseMs': 200,
        'curve': 1,
        'invert': false,
      });
      final result = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(result.problems, isEmpty);
      expect(result.composition, composition);
      expect(result.composition.findClip('g')!.clip.source, generatorRef(audioOrigin: ms(250)));
    });

    test('writes an active reactivity, omits none and salvages an unreadable one', () {
      const reactivity = AudioReactivity(
        enabled: true,
        range: AudioRangePreset.mids,
        sensitivity: 1.5,
        modes: {
          ReactiveModeKind.brightness: ReactiveMode(min: 0.3, max: 1),
          ReactiveModeKind.flash: ReactiveMode(min: 0, max: 0.8, trigger: ReactiveTrigger.onset),
        },
      );
      final composition = withGenerator(audioOrigin: ms(250))
          .setReactivity('g', reactivity)
          .setEffectBindings('g', const {'speed': ConstantBinding(1.5)});
      final json = jsonOf(composition);
      final generator = (clipsOf(firstTrack(json))[1]! as Map<String, Object?>)['source']! as Map<String, Object?>;
      expect(generator['reactivity'], AudioReactivityJson.toJson(reactivity));
      expect((generator['reactivity']! as Map<String, Object?>)['range'], 'mids');
      final result = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(result.problems, isEmpty);
      expect(result.composition, composition);
      expect((result.composition.findClip('g')!.clip.source as GeneratorRef).reactivity, reactivity);

      final plain =
          (clipsOf(firstTrack(jsonOf(withGenerator())))[1]! as Map<String, Object?>)['source']! as Map<String, Object?>;
      expect(plain.containsKey('reactivity'), isFalse);

      generator['reactivity'] = 'loud';
      final salvaged = IcprojCodec.fromJson(json);
      expect((salvaged.composition.findClip('g')!.clip.source as GeneratorRef).reactivity, AudioReactivity.none);
      expect(salvaged.problems.single.kind, IcprojProblemKind.defaultedValue);
      expect(salvaged.problems.single.path, r'$.tracks[0].clips[1].source.reactivity');
    });

    test('omit audioOriginUs when the generator does not use audio', () {
      final json = jsonOf(withGenerator());
      final generator = (clipsOf(firstTrack(json))[1]! as Map<String, Object?>)['source']! as Map<String, Object?>;
      expect(generator.containsKey('audioOriginUs'), isFalse);
      final decoded = IcprojCodec.fromJson(json).composition.findClip('g')!.clip.source as GeneratorRef;
      expect(decoded.audioOrigin, isNull);
    });

    test('compositions without generator clips are still written as version 1 without a source type', () {
      final json = jsonOf(fullComposition());
      expect(json['version'], 1);
      expect(IcprojCodec.versionFor(fullComposition()), 1);
      expect(IcprojCodec.versionFor(withGenerator()), 2);
      for (final clip in clipsOf(firstTrack(json))) {
        expect(((clip! as Map<String, Object?>)['source']! as Map<String, Object?>).containsKey('type'), isFalse);
      }
    });

    test('a classic region of a version 1 document is written as the old string', () {
      final json = jsonOf(fullComposition());
      final clips = clipsOf(firstTrack(json));
      expect((clips[0]! as Map<String, Object?>)['region'], 'all');
      expect((clips[1]! as Map<String, Object?>)['region'], 'radioPanels');
      final top = (json['tracks']! as List<Object?>)[1]! as Map<String, Object?>;
      expect((clipsOf(top)[0]! as Map<String, Object?>)['region'], 'icicles');
    });

    test('a version 1 file re-encodes byte-identically', () {
      final text = File('test/codec/fixtures/show_v1.icproj').readAsStringSync();
      final result = IcprojCodec.decode(text);
      expect(result.problems, isEmpty);
      expect(result.composition, fullComposition());
      expect(IcprojCodec.encode(result.composition), text);
    });

    test('reads a version 2 file source and refuses unknown source types', () {
      final json = jsonOf(withGenerator());
      expect(IcprojCodec.fromJson(json).composition.findClip('f')!.clip.source, ref('a'));
      final clip = clipsOf(firstTrack(json))[0]! as Map<String, Object?>;
      (clip['source']! as Map<String, Object?>)['type'] = 'hologram';
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.findClip('f'), isNull);
      expect(result.problems.single.kind, IcprojProblemKind.droppedClip);
    });

    test('drops a clip with an invalid generator source', () {
      final json = jsonOf(withGenerator());
      final clip = clipsOf(firstTrack(json))[1]! as Map<String, Object?>;
      (clip['source']! as Map<String, Object?>).remove('lengthUs');
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.findClip('g'), isNull);
      expect(result.composition.findClip('f'), isNotNull);
      expect(result.problems.single.kind, IcprojProblemKind.droppedClip);
      expect(result.problems.single.path, r'$.tracks[0].clips[1]');
    });

    test('drops unreadable bindings, defaults the seed and keeps the clip', () {
      final json = jsonOf(withGenerator());
      final clip = clipsOf(firstTrack(json))[1]! as Map<String, Object?>;
      final source = clip['source']! as Map<String, Object?>;
      source.remove('seed');
      final params = source['params']! as Map<String, Object?>;
      params['level'] = {'type': 'audio', 'feature': 'nope', 'min': 0, 'max': 1};
      params['fade'] = 'linear';
      final result = IcprojCodec.fromJson(json);
      final decoded = result.composition.findClip('g')!.clip.source as GeneratorRef;
      expect(decoded.seed, 0);
      expect(decoded.bindings.keys, isNot(contains('level')));
      expect(decoded.bindings.keys, isNot(contains('fade')));
      expect(decoded.bindings['speed'], const ConstantBinding(1.5));
      expect(result.problems.map((problem) => problem.kind),
          containsAll([IcprojProblemKind.droppedBinding, IcprojProblemKind.defaultedValue]));
      expect(result.problems.map((problem) => problem.path), contains(r'$.tracks[0].clips[1].source.params.level'));
    });

    test('forces speed 1, no loop and a trim within the length on generator clips', () {
      final json = jsonOf(withGenerator());
      final clip = clipsOf(firstTrack(json))[1]! as Map<String, Object?>;
      clip['speed'] = 2;
      clip['loopDurationUs'] = 8000000;
      clip['sourceOutUs'] = 9000000;
      (clip['source']! as Map<String, Object?>)['lengthUs'] = const Duration(minutes: 11).inMicroseconds;
      final result = IcprojCodec.fromJson(json);
      final decoded = result.composition.findClip('g')!.clip;
      expect(decoded.speed, 1.0);
      expect(decoded.loopDuration, isNull);
      expect(decoded.sourceOut, s(9));
      expect((decoded.source as GeneratorRef).length, maxBakeLength);
      expect(
          result.problems.map((problem) => problem.path),
          containsAll([
            r'$.tracks[0].clips[1].speed',
            r'$.tracks[0].clips[1].loopDurationUs',
            r'$.tracks[0].clips[1].source.lengthUs',
          ]));
    });
  });

  group('regions', () {
    Composition withRegion(Region region) => Composition(
          name: 'Masked',
          target: testSpec(radioPanelsCount: 4),
          tracks: [
            VisualTrack(id: 't', clips: [testClip('a', sourceOut: s(1), region: region)]),
          ],
        );

    Map<String, Object?> regionJson(Composition composition) =>
        (clipsOf(firstTrack(jsonOf(composition))).single! as Map<String, Object?>)['region']! as Map<String, Object?>;

    test('a non-classic region makes the document version 2 and round-trips', () {
      final region = Region(columns: ColumnRange(2, 2), panels: const RegionPanels.some({3, 1}));
      final composition = withRegion(region);
      expect(IcprojCodec.versionFor(composition), 2);
      expect(jsonOf(composition)['version'], 2);
      expect(regionJson(composition), {
        'icicles': true,
        'columns': [2, 2],
        'panels': [1, 3],
      });
      final result = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(result.problems, isEmpty);
      expect(result.composition, composition);
      expect(result.composition.findClip('a')!.clip.region, region);
    });

    test('writes "all"/"none" panels and omits columns in version 2 objects', () {
      expect(regionJson(withRegion(const Region(icicles: false, panels: RegionPanels.none()))),
          {'icicles': false, 'panels': 'none'});
      final withGeneratorAndClassic = Composition(
        name: 'Gen',
        target: testSpec(),
        tracks: [
          VisualTrack(id: 't', clips: [
            testClip('g',
                source: GeneratorRef(generatorId: 'icicles.rain', generatorVersion: 1, seed: 1, length: s(4)),
                sourceOut: s(1),
                region: const Region.iciclesOnly()),
          ]),
        ],
      );
      expect(regionJson(withGeneratorAndClassic), {'icicles': true, 'panels': 'none'});
      final decoded = IcprojCodec.decode(IcprojCodec.encode(withGeneratorAndClassic));
      expect(decoded.problems, isEmpty);
      expect(decoded.composition.findClip('g')!.clip.region, const Region.iciclesOnly());
    });

    test('reads version 2 objects also in a version 1 document and salvages bad ones', () {
      final composition = withRegion(const Region.all());
      Clip decodeWith(Object? region, List<IcprojProblem> problems) {
        final json = jsonOf(composition);
        (clipsOf(firstTrack(json)).single! as Map<String, Object?>)['region'] = region;
        final result = IcprojCodec.fromJson(json);
        problems.addAll(result.problems);
        return result.composition.findClip('a')!.clip;
      }

      var problems = <IcprojProblem>[];
      expect(
          decodeWith({
            'icicles': true,
            'panels': [2, 4]
          }, problems)
              .region,
          const Region(panels: RegionPanels.some({2, 4})));
      expect(problems, isEmpty);

      problems = <IcprojProblem>[];
      expect(
          decodeWith({
            'icicles': 'yes',
            'columns': [1],
            'panels': 'some'
          }, problems)
              .region,
          const Region.all());
      expect(problems.map((problem) => problem.path), [
        r'$.tracks[0].clips[0].region.icicles',
        r'$.tracks[0].clips[0].region.columns',
        r'$.tracks[0].clips[0].region.panels',
      ]);
      expect(problems.map((problem) => problem.kind), everyElement(IcprojProblemKind.defaultedValue));

      problems = <IcprojProblem>[];
      expect(decodeWith(['icicles'], problems).region, const Region.all());
      expect(problems.single.path, r'$.tracks[0].clips[0].region');

      problems = <IcprojProblem>[];
      expect(
          decodeWith({
            'columns': [1, 2]
          }, problems)
              .region,
          Region(columns: ColumnRange(1, 2)));
      expect(
          decodeWith({
            'columns': [2, 1]
          }, problems)
              .region,
          const Region.all());
      expect(
          decodeWith({
            'columns': [-1, 1]
          }, problems)
              .region,
          const Region.all());
      expect(
          decodeWith({
            'panels': [0, 1]
          }, problems)
              .region,
          const Region.all());
      expect(problems, hasLength(3));
    });

    test('fits decoded regions to the target and reports it', () {
      final json = jsonOf(withRegion(const Region.all()));
      (clipsOf(firstTrack(json)).single! as Map<String, Object?>)['region'] = {
        'columns': [1, 50],
        'panels': [1, 2, 9],
      };
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.findClip('a')!.clip.region,
          Region(columns: ColumnRange(1, 2), panels: const RegionPanels.some({1, 2})));
      expect(result.problems.single.kind, IcprojProblemKind.clampedValue);
      expect(result.problems.single.path, r'$.tracks[0].clips[0].region');
    });
  });

  group('pixel masks and mask clips', () {
    final target = testSpec(radioPanelsCount: 4); // 6 icicle + 4 panel pixels
    Composition withClip(Clip clip) => Composition(name: 'Masked', target: target, tracks: [
          VisualTrack(id: 't', clips: [clip]),
        ]);
    Map<String, Object?> clipJson(Composition composition) =>
        clipsOf(firstTrack(jsonOf(composition))).single! as Map<String, Object?>;

    test('a pixel mask is written as base64 bits in version 2 and round-trips', () {
      final mask = PixelMask.full(target).withPixel(0, false).withPanelPixel(2, 0, false).withPanelPixel(4, 0, false);
      final composition = withClip(testClip('a', sourceOut: s(1), region: Region(pixels: mask)));
      expect(IcprojCodec.versionFor(composition), 2);
      final region = clipJson(composition)['region']! as Map<String, Object?>;
      expect(region['pixels'], {
        'x': 3,
        'y': 2,
        'panels': 4,
        'panelPixels': 1,
        'bits': base64Encode(mask.bits),
      });
      // Icicle pixels first: bit 0 cleared, bit 7 (panel 2's LED) cleared, bit 9 (panel 4) cleared.
      expect(mask.bits, [0x7E, 0x01]);
      final result = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(result.problems, isEmpty);
      expect(result.composition, composition);
      expect(result.composition.findClip('a')!.clip.region.pixels, mask);
    });

    test('a mask clip is written with "mask": true in version 2 and round-trips', () {
      final composition = withClip(testClip('a', sourceOut: s(1), isMask: true));
      expect(IcprojCodec.versionFor(composition), 2);
      expect(clipJson(composition)['mask'], isTrue);
      expect(clipJson(withClip(testClip('a', sourceOut: s(1)))).containsKey('mask'), isFalse);
      final result = IcprojCodec.decode(IcprojCodec.encode(composition));
      expect(result.problems, isEmpty);
      expect(result.composition.findClip('a')!.clip.isMask, isTrue);
    });

    test('an unreadable pixel mask falls back to every pixel with a problem; other dimensions are fitted', () {
      final composition = withClip(testClip('a', sourceOut: s(1), region: Region(columns: ColumnRange(0, 1))));
      Clip decodeWith(Object? pixels, List<IcprojProblem> problems) {
        final json = jsonOf(composition);
        final region = (clipsOf(firstTrack(json)).single! as Map<String, Object?>)['region']! as Map<String, Object?>;
        region['pixels'] = pixels;
        final result = IcprojCodec.fromJson(json);
        problems.addAll(result.problems);
        return result.composition.findClip('a')!.clip;
      }

      for (final bad in [
        'bits',
        {'x': 3, 'y': 2, 'panels': 4, 'panelPixels': 1, 'bits': '***'},
        {
          'x': 3,
          'y': 2,
          'panels': 4,
          'panelPixels': 1,
          'bits': base64Encode([0xFF])
        },
        {
          'x': 3,
          'y': 2,
          'panels': 4,
          'bits': base64Encode([0xFF, 0x03])
        },
        {'x': -3, 'y': 2, 'panels': 4, 'panelPixels': 1, 'bits': ''},
      ]) {
        final problems = <IcprojProblem>[];
        final clip = decodeWith(bad, problems);
        expect(clip.region, Region(columns: ColumnRange(0, 1)), reason: '$bad');
        expect(problems.single.kind, IcprojProblemKind.defaultedValue);
        expect(problems.single.path, r'$.tracks[0].clips[0].region.pixels');
      }

      final problems = <IcprojProblem>[];
      final smaller = PixelMask.empty(testSpec()).withPixel(1, true);
      final clip =
          decodeWith({'x': 3, 'y': 2, 'panels': 0, 'panelPixels': 1, 'bits': base64Encode(smaller.bits)}, problems);
      expect(problems.single.kind, IcprojProblemKind.clampedValue);
      final fitted = clip.region.pixels!;
      expect(fitted.fits(target), isTrue);
      expect(fitted.contains(1), isTrue);
      expect(fitted.contains(0), isFalse);
      expect(fitted.containsPanelPixel(1, 0), isTrue);
    });

    test('a non-boolean mask flag defaults to false with a problem', () {
      final json = jsonOf(withClip(testClip('a', sourceOut: s(1))));
      (clipsOf(firstTrack(json)).single! as Map<String, Object?>)['mask'] = 'yes';
      final result = IcprojCodec.fromJson(json);
      expect(result.composition.findClip('a')!.clip.isMask, isFalse);
      expect(result.problems.single.path, r'$.tracks[0].clips[0].mask');
    });
  });
}

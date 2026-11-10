# icicles_composition

Timeline compositions of [icicles](https://github.com/led-icicles) animations: smaller `.anim` clips and parametric
**generator clips** (code-generated, audio-reactive animations from `icicles_generators`) layered on tracks over a music
track (trim, stretch, loop, blend, crossfade) and rendered into one `.anim` animation.

Pure Dart (no Flutter, no `dart:io`). It depends on
[icicles_animation_dart](https://github.com/led-icicles/icicles_animation_dart) `v3.2.0`, whose `Animation`,
`AnimationIndex`, `Framerate`, `BlendMode` and `Color.composite` it uses, and on
[icicles_generators](https://github.com/led-icicles/icicles_generators), whose `Tempo`, `frameIndexAt`/`frameCountFor`,
`ParamBinding` (+ JSON form) and `maxBakeLength` it re-exports or uses for generator clips. File access, path
resolution and the baking of generator clips (rendering a `GeneratorRef` into an `AnimationIndex` at the target layout)
are left to the application.

```yaml
dependencies:
  icicles_composition:
    git:
      url: git@github.com:led-icicles/icicles_composition.git
      ref: v0.4.0
```

While the repositories are unpublished, use path dependencies on sibling checkouts (`path: ../icicles_composition`,
which itself resolves `icicles_generators` from `../icicles_generators`).

## Model

All model classes are immutable, `Equatable` and have `copyWith`. Constructors throw an `ArgumentError` for values
outside their ranges; the edit operations clamp first.

| Class | Fields |
|---|---|
| `Composition` | `name` (no NUL), `target: OutputSpec`, `framerate` (30 or 45 fps), `tracks` (bottom to top), `audio: AudioRef?`, `tempo: Tempo?`, `markers`, `macros` (`MacroDef { id, name, kind: number \| color, min, max, defaultValue, binding }`, global bindings read through `MacroBinding`; `macroBindings`, `macrosUsedBy(bindings)`); derived `duration` = end of the last clip |
| `OutputSpec` | `xCount`, `yCount`, `radioPanelsCount`, `radioPanelPixelCount`, `version: AnimationVersion` |
| `VisualTrack` | `id`, `name`, `muted`, `locked`, `opacity`, `clips` (sorted, never overlapping), `transitions` |
| `Clip` | `id`, `source: SourceRef`, `start`, `sourceIn`, `sourceOut` (the trim), `speed` (0.1–10), `loopDuration: Duration?`, `blend: BlendMode`, `opacity`, `fadeIn`, `fadeOut`, `region: Region`, `isMask` (a track matte, see Rendering) |
| `Region` | `icicles`, `columns: ColumnRange?` (0-based, inclusive), `panels: RegionPanels` (`all()`, `none()`, `some({1-based})`), `pixels: PixelMask?` (per-pixel bit set, `null` = every pixel) |
| `PixelMask` | bits over the icicle pixels (column-major `x · yCount + y`) then the radio panel pixels, plus the dimensions it was made for; `full`/`empty(target)`, `contains`, `containsPanelPixel(panel, led)`, `withPixel`, `withPanelPixel`, `withPixels`, `inverted()`, `fitTo(target)`, `coveredCount`, `isFull`, `isEmpty` |
| `Transition` | `id`, `fromClipId`, `toClipId` (adjacent clips of one track), `duration`, `alignment` (`center`, `startAtCut`, `endAtCut`) |
| `SourceRef` | sealed: `AnimationFileRef { path (as stored, relative to the project by convention), contentHash (opaque fingerprint for offline detection) }`, `GeneratorRef { generatorId, generatorVersion, … }` or `EffectRef { effectId, effectVersion, … }` — the last two share the sealed base `ParametricRef { programId, programVersion, bindings: Map<String, ParamBinding>, seed, length (≤ `maxBakeLength`), audioOrigin? }` from _icicles_generators_; equal refs share one bake / are one source. An effect clip (`Clip.isEffect`) is an adjustment layer over the tracks below, see Rendering |
| `AudioRef` | `path`, `gain` (linear, 0–4), `offset` (timeline time of the file start; negative skips its beginning) |
| `Tempo` | `bpm` (20–400), `firstBeatOffset` (re-exported from _icicles_generators_, like `frameIndexAt`/`frameCountFor`) |
| `Marker` | `id`, `at`, `label` |

### Clip timing

- The only length on the timeline is the derived `Clip.duration`:
  - `loopDuration == null`: one pass, `round((sourceOut − sourceIn) / speed)` µs;
  - otherwise `loopDuration`, repeating the trimmed range.
- Source time at timeline `t` (`Clip.sourceTimeAt`) is `sourceIn + floor((t − start) · speed)`, wrapped modulo the
  range when looping, then clamped to `[sourceIn, sourceOut − 1 µs]`. It is rounded **down**, never to nearest: with a
  1 s range at speed 0.1 the last µs of the 10 s clip maps to 999 999.9 µs, which rounding would turn into `sourceOut`
  (past the source end).

### Transitions

A transition crossfades two touching clips (gap ≤ 1 ms) of one track. Its window lies around the cut (`center`), or
fully after/before it. In the window the outgoing clip continues past its end and the incoming one starts early:
material after `sourceOut` (before `sourceIn`) is used when the source has it, a looping clip keeps cycling, and where
nothing is left the edge frame holds (`frozenTransitionParts` reports how long, for a "frozen frames" hint).

`fitTransitions` limits a transition to `min(from.duration, to.duration)` and keeps the two windows inside one clip
from overlapping. The incoming clip's alpha is weighted by the progress `p`, the outgoing one by
`(1 − p) / (1 − p·s)` (`s` = the incoming clip's alpha factor), so the outgoing clip's visible share falls linearly:
a true dissolve for opaque clips.

## Edit operations

`CompositionEdits` (an extension on `Composition`) returns a new composition or throws a
`CompositionException(CompositionErrorKind, message)`:

- tracks: `addTrack`, `removeTrack`, `reorderTrack`, `updateTrack`;
- clips: `addClip` (a file clip needs its `SourceInfo` and is rejected when the header is not `hasSameLayout` with the
  target: `CompositionErrorKind.layoutMismatch`; a generator clip needs none), `moveClip` (across tracks too),
  `splitClip`, `removeClip`, `duplicateClip`, `setClipProps`, `setClipMask`, `setClipSpeed`, `setClipLoop`, `dragClipEdge`,
  `setGeneratorBindings`, `setGeneratorSeed` (both also for effect clips: aliases `setEffectBindings`, `setEffectSeed`);
- transitions: `addTransition`, `updateTransition`, `removeTransition`;
- `addMarker`, `updateMarker`, `removeMarker`, `setAudio`, `setTempo`.

Rules:

- Clips on one track never overlap. A move lands in the free gap nearest to the requested start that fits the clip, so
  an overlap is clamped to the neighbour's edge; trims and stretches stop at the neighbours. Crossfades exist only as
  explicit transitions.
- Edge drag (`dragClipEdge`): on a clip without a loop a plain drag trims (`sourceIn`/`sourceOut`, clamped to the
  source); on a looping clip the end edge sets `loopDuration` and the start edge trims `sourceIn` keeping the end fixed;
  `stretch: true` (Shift) changes `speed` and keeps the trim, scaling `loopDuration` of a looping clip.
- `setClipLoop(enabled: true)` sets `loopDuration = duration`; `false` removes it and clamps the clip to one pass.
- Generator and effect clips (`ParametricRef`) always play at speed 1 and never loop (`setClipSpeed`/`setClipLoop`
  refuse with `invalidValue`; an effect clip is never a mask, `setClipMask` refuses too); their end edge grows or
  shrinks the ref's `length` together with `sourceOut` (stretch acts like trim, at most `maxBakeLength`), the start edge
  trims `sourceIn`. When `audioOrigin` is set, every edit keeps it at `clip.start − sourceIn − audio.offset`
  (`audioOriginFor`, `reanchorGeneratorClips`), also `setAudio`.
- Clips of a locked track cannot change (`CompositionErrorKind.trackLocked`).
- Transitions that no longer join adjacent clips are removed after every edit, and the others re-limited.

`Snapper` snaps a time (`snap`) or a moving span (`snapSpan`) to the playhead, clip edges, markers and beats within a
tolerance the caller derives from its zoom.

## Rendering

Sources are single-pass indexes, `animation.toIndex()`, keyed by `SourceRef` (memory: frames × pixels per source,
fine for icicle grids): decoded files for `AnimationFileRef`s, bakes made by the application at the target layout for
`GeneratorRef`s (an absent bake is `OfflineReason.missing`; `generatorUnavailable`/`generatorFailed` exist for the
application to report). `EffectRef` clips have no index: their effect runs per frame through the `EffectHost` the
application passes (`effects:`), `AnimationView apply(clipId, ref, frameIndex, input)` with `frameIndex =
frameIndexAt(framerate, sourceTime)` of the clip, asked in timeline order within one render (an `EffectRunner` of
_icicles_generators_ per clip fits); an `EffectHostException` (`unavailable`/`failed`) or no host makes the clip
offline (`OfflineReason.effectUnavailable`/`effectFailed`) and its input passes through.

- Effect clips are adjustment layers: while active, the picture accumulated so far (the tracks below and the earlier
  layers of the clip's track) is the effect's input, and the result is composited back over it with the clip's blend
  mode at the usual alpha factor (so opacity and fades mix the processed picture with the input) inside the clip's
  region only — elsewhere the input passes through; the tracks above continue over the result.
- `Compositor.renderAt(composition, sources, time, {effects})` → `AnimationView`: starts from opaque black, composites every
  unmuted track bottom up with `Color.composite(source, destination, clip.blend)`; each source color's alpha is scaled
  by `clip.opacity × fade × track.opacity × transitionWeight`. Regions mask icicle columns, radio panels and, with a
  `PixelMask`, single pixels (the three are intersected; blended per panel and LED). Clips whose source is missing,
  empty or of another shape are not drawn.
- Mask layers (`Clip.isMask`): a mask clip is not drawn. At every pixel of its region, the luminance
  (`Color.computeLuminance`, i.e. linearized sRGB — a mid gray gives ≈0.22, white 1) of its composited output (its
  colors with the clip opacity, fades and transition weight over black) multiplies the color the tracks below it (and
  the earlier layers of its own track) have accumulated so far — a track matte. Outside the region the lower tracks stay
  untouched; the tracks above are composited afterwards and are unaffected. Because the background is opaque black,
  scaling the accumulated color toward black is equivalent to scaling its alpha over that background.
- `Compositor.render(composition, sources, {effects, range, duration})` → `RenderResult { animation, warnings }`: frame `i` is `renderAt` at
  `framerate.frameStart(i)` written with `Icicles.setView` + `show(framerate.frameDuration(i))` — the library's
  drift-free millisecond grid (22/22/23 ms at 45 fps), so a 3-minute composition exports as exactly 3:00 and the
  preview (sampling the same instants via `frameIndexAt`) is frame-identical to the file. The animation uses the target
  header, `loopsCount: 1`, `optimize: true` and `useRgb565: false`. Warnings:
  - `OfflineSourcesWarning` (`RenderWarningKind.offlineSources`): clips of unmuted tracks that were not drawn;
  - `FirmwareDelayTruncationWarning` (`RenderWarningKind.firmwareDelayTruncation`): standalone delay frames longer than
    255 ms (static stretches beyond ~65.5 s); the controller may shorten these pauses.

## The `.icproj` format

UTF-8 JSON, written by `IcprojCodec.encode` with sorted keys, a two-space indent and a trailing newline. Times are
integer microseconds in fields ending with `Us`.

```json
{
  "format": "icproj",
  "version": 1,
  "name": "Show",
  "framerate": 30,
  "target": {"animationVersion": 2, "radioPanelPixelCount": 1, "radioPanelsCount": 2, "xCount": 20, "yCount": 24},
  "tracks": [
    {
      "id": "t1", "name": "Base", "muted": false, "locked": false, "opacity": 1.0,
      "clips": [
        {
          "id": "c1",
          "source": {"path": "clips/intro.anim", "contentHash": "…"},
          "startUs": 0, "sourceInUs": 0, "sourceOutUs": 2000000, "speed": 1.0,
          "loopDurationUs": 8000000,
          "blend": "normal", "opacity": 1.0, "fadeInUs": 0, "fadeOutUs": 0, "region": "all"
        }
      ],
      "transitions": [
        {"id": "x1", "fromClipId": "c1", "toClipId": "c2", "durationUs": 500000, "alignment": "center"}
      ]
    }
  ],
  "audio": {"path": "music/song.mp3", "gain": 1.0, "offsetUs": 0},
  "tempo": {"bpm": 128.0, "firstBeatOffsetUs": 120000},
  "markers": [{"id": "m1", "atUs": 30000000, "label": "Drop"}]
}
```

- `loopDurationUs`, `audio` and `tempo` are omitted when absent. Paths are stored as given; resolving them against the
  project file is the application's job.
- Version 2 adds generator and effect clips: a clip `source` carries a `type`, `{"type": "file", "path", "contentHash"}`,
  `{"type": "generator", "id", "version", "seed", "lengthUs", "audioOriginUs"?, "params": {paramId: binding}}` or the
  same shape with `"type": "effect"` (bindings in the `ParamBindingJson` form of _icicles_generators_). A composition
  without generator or effect clips is still
  written as version 1 (the shape above, no `type`), byte-identical to before; the codec reads both versions
  (`IcprojCodec.supportedVersions`, `versionFor(composition)`).
- Version 2 also holds the non-classic regions, `{"icicles": bool, "columns": [first, last]?, "panels": "all" | "none"
  | [1, 3, …], "pixels"?: {"x", "y", "panels", "panelPixels", "bits": base64}}` (the pixel mask's bits packed
  little-endian, icicle pixels first then panel pixels, omitted when absent), and mask clips (`"mask": true`, omitted
  when false). A composition with classic regions, no pixel masks, no mask clips and no generator clips is still
  written as version 1.
- `IcprojCodec.decode` throws `IcprojException(IcprojErrorKind, message)` for invalid JSON (`invalidJson`), another
  `format` (`notIcproj`), a version other than 1 or 2 (`unsupportedVersion`) and a missing/invalid version or target
  (`invalidProject`).
- Everything else is salvaged and reported in `IcprojDecodeResult.problems` (`IcprojProblem(kind, path, message)`):
  - an invalid track, clip (also one overlapping an earlier clip or repeating an id, or one with an invalid
    generator source), transition or marker is dropped (`dropped…`), and an invalid `audio` or `tempo` is removed;
    an unreadable generator/effect binding is dropped (`droppedBinding`, the parameter uses its default), a generator
    or effect clip's `speed`/`loopDurationUs` are forced to 1/none and `mask` is dropped on an effect clip;
  - numbers are clamped to their ranges (`clampedValue`); an unsupported framerate becomes the nearest supported one;
    a region (column range, panel indices, pixel mask dimensions) is fitted to the target;
  - an unreadable region falls back to every pixel, an unreadable pixel mask to no mask (`defaultedValue`);
  - unknown enum values and malformed optional fields fall back to defaults (`defaultedValue`);
  - unknown fields are ignored.

## Development

```sh
dart pub get
dart analyze
dart test
```

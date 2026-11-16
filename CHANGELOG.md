## 0.11.0

- Cue tracks (timing tracks of user-placed marks that cue triggers fire on): `Cue {id, at, strength}`,
  `CueTrack {id, name, color, cues}` (sorted; `hits(offset:)` gives the `CueHits` of a bake),
  `Composition.cueTracks`, `cueTrackById`, `cueTrackFor(ref)` (the ref's `cueTrackId`, else the first track).
- `ParametricRef.cueTrackId` (`GeneratorRef` / `EffectRef`, `copyWith(cueTrackId:, removeCueTrackId:)`, part of
  equality).
- Edits: `addCueTrack`, `updateCueTrack`, `removeCueTrack` (clears the clip references), `addCues`, `replaceCues`,
  `moveCues` (clamped together at 0), `setCueStrength`, `removeCues`, `setCueTrack(clipId, id, {audioBound})`; new
  `CompositionErrorKind.cueTrackNotFound` / `cueNotFound`.
- `.icproj` version 2: `"cueTracks": [{id, name, color?, cues: {ids, us, s}}]` and a source's `"cueTrack"`;
  unreadable entries are dropped (`IcprojProblemKind.droppedCueTrack` / `droppedCue`).
- `Snapper` snaps to cues (`SnapTargetKind.cue`, `cues`, `ignoreCueIds`); `SnapTargetKind.audioHit` labels
  host-added targets (detected drum hits).
- Depends on `icicles_generators` 0.9.0.

## 0.10.1

- Depends on `icicles_generators` 0.8.0: `.icproj` documents round-trip the new drum triggers unchanged — the
  Strobe `trigger` values `kick`/`snare`/`hihat`/`cymbals`/`drums`, `AudioReactivity` triggers `kick`/`snare`/
  `hihat`/`drums` and the `drumHit` envelope trigger (all encoded by the generators package's JSON codecs).

## 0.10.0

- Universal audio reactivity: `ParametricRef.reactivity: AudioReactivity` (`GeneratorRef` and `EffectRef`
  constructors and `copyWith(reactivity:)`, part of equality; `AudioReactivity.none` by default). A ref with an
  active reactivity is audio-bound: `setReactivity(clipId, reactivity, {bool? audioBound})` (normalizes the value,
  anchors `audioOrigin` at `audioOriginFor` when the reactivity is active, otherwise keeps / sets / clears it
  per `audioBound`; `invalidValue` for a file clip, `clipNotFound`, `trackLocked`), `applyAttributes` copies the
  template's reactivity with its parameter bindings (`params`) and binds the target when it is active.
- `.icproj` version 2 generator and effect sources carry `"reactivity": {…}` (`AudioReactivityJson`), omitted
  while it is `none`; an unreadable value falls back to none with `defaultedValue` at `….source.reactivity`.
- Depends on `icicles_generators` 0.7.0.

## 0.9.0

- Media sources. _SourceRef_ gains three *indexed* kinds (`SourceRef.isIndexed`: the application supplies the `AnimationIndex` and the `SourceInfo`, like a file): `ImageRef { paths, contentHash, fit: ImageFit.cover | contain | stretch, panels: ImagePanelMode.average | off, frameDuration? }` (one image file, an animated GIF/APNG, or a sequence of files — `ImageRef.single`, `path`, `isSequence`, `defaultFrameDuration` 1/30 s; the application decodes and scales it onto the target), `DrawingRef { id, name, xCount, yCount, radioPanelsCount, radioPanelPixelCount, frames: List<DrawingFrame { duration, pixels: RGB bytes — icicle pixels column-major, then the panel pixels }> }` (a clip drawn by hand and stored in the project; `DrawingRef.blank`, `toViews()`, `header`, `fits(target)`, `panelPixelIndex`, `duration`, `DrawingFrame.blank`/`withPixels`/`colorAt`) and `CompositionRef { path, contentHash }` (a nested project the application renders at the parent target). `SourceInfo.ofDrawing`.
- Edits: `addClip` needs the _SourceInfo_ for every indexed source (`invalidValue` without one, `layoutMismatch` like a file); new `setClipSource(clipId, source, [info])` replaces a clip's source (an edited drawing, an image with other options): the trim is kept where it fits and clamped otherwise (a `sourceIn` beyond the new end restarts at 0), the end stops at the next clip; an indexed source never turns parametric or vice versa (`invalidValue`).
- `.icproj` version 2 sources: `{type: "image", path | paths, contentHash, fit, panels, frameDurationUs?}`, `{type: "drawing", id, name, x, y, panels, panelPixels, frames: [{durationUs, pixels}]}` (pixels run-length + Base64 encoded, `DrawingPixelsCodec`) and `{type: "composition", path, contentHash}`; unknown fit/panel modes and a non-positive frame duration fall back to the defaults (`defaultedValue`), an unreadable drawing frame is dropped with the new `IcprojProblemKind.droppedFrame` (a drawing without a readable frame drops its clip). `IcprojCodec.sourceToJson` / `sourceFromJson` read and write one source outside a document. Any non-file source makes the document version 2.

## 0.8.0

- Audio segments. _AudioRef_ is replaced by _AudioTrack_ `{path, gain, segments: List<AudioSegment>}`: one music file played as sorted, non-overlapping segments. _AudioSegment_ `{id, start (timeline), sourceIn, sourceOut?}` plays the file range from `start` at speed 1; `sourceOut` `null` means "to the end of the file" (the model does not know the file length; only the last segment may be open-ended, `endFor(sourceLength)` / `sourceOutFor` resolve it), `offset` = `start − sourceIn`, `contains`, `sourceTimeAt`, `AudioSegment.minDuration` (1 ms). `AudioTrack.single(path:, gain:, offset:)` is the plain soundtrack (one open-ended segment; a negative offset skips the file start), `isSingleWhole`, `offset` (the first segment's), `segmentById`, `segmentAt(time, sourceLength:)` (null in a gap), `segmentFor(time)` (the segment playing there, else the preceding one, else the first) and `offsetAt(time)` — the per-segment song-time mapping `audioOriginFor` / `reanchorGeneratorClips` now use at the clip start, `end` / `endFor`.
- Edits: `setAudio(AudioTrack?)`, `setAudioOffset(offset)` (moves every segment together), `setAudioGain`, `splitAudio(at, newSegmentId:, sourceLength:)` (`invalidSplit` outside a segment), `moveAudioSegment(id, start, sourceLength:)` (nearest free gap, never overlapping or before 0), `trimAudioSegment(id, AudioEdge.start | end, delta, sourceLength:)` (stopped at the file bounds, the neighbours and the minimum; the end edge of an open-ended segment needs the length, an end on the file end stays open-ended), `removeAudioSegment(id)` (the last one removes the track); new `CompositionErrorKind.audioSegmentNotFound`.
- Project settings edits: `setTarget(OutputSpec)` keeps every clip and fits the regions (pixel masks included) to the new layout, `setFramerate`, `rename` (`invalidValue` when refused by the model).
- `.icproj`: a plain soundtrack keeps the version 1 shape `{path, gain, offsetUs}` (byte-identical); a split, moved or trimmed one is written as version 2 `{path, gain, segments: [{id, startUs, sourceInUs, sourceOutUs?}]}`. Unreadable or overlapping segments are dropped with `droppedAudio` at the segment's path.

## 0.7.0

- Macros. _Composition_ gains `macros: List<MacroDef>` (unique ids, `macroById`, `macroBindings` — what a bake takes as `BakeRequest.macros` — and `macrosUsedBy(bindings)`, the subset the given bindings read). `MacroDef { id, name, kind: MacroKind.number | color, min, max, defaultValue (double | Color), binding }` (`MacroDef.number(...)` / `MacroDef.color(...)`, `spec` — the `NumberParam`/`ColorParam` the binding is salvaged against at construction, `copyWith`). `macroIdsOf(binding)` walks a binding (stack base, modulator sources and depth bindings) for the macro ids it reads.
- Edits: `addMacro` (`duplicateId`), `updateMacro(id, name:, min:, max:, defaultValue:)` (the binding is re-salvaged against the new range), `setMacroBinding(id, binding)`, `removeMacro(id)`; new `CompositionErrorKind.macroNotFound`. `applyAttributes` copies `MacroBinding`s like any other binding.
- `.icproj` version 2: `"macros": [{"id", "name", "kind", "min", "max", "default" | "defaultColor", "binding"}]`, omitted when empty (a composition with macros is version 2). Unreadable macros are dropped with the new `IcprojProblemKind.droppedMacro`; an inverted range falls back to `0..1`, an unreadable binding to the default (`droppedBinding`).

## 0.6.0

- Effect clips (adjustment layers). _SourceRef_ gains a third kind, `EffectRef { effectId, effectVersion, bindings, seed, length, audioOrigin? }`; `GeneratorRef` and `EffectRef` share the sealed base `ParametricRef` (`programId`, `programVersion`, `bindings`, `seed`, `length`, `audioOrigin`, `usesAudio`, `copyWith`). `Clip.isEffect`, `Clip.isParametric`; an effect clip plays at speed 1, never loops and is never a mask (`ArgumentError`, `setClipMask` refuses with `invalidValue`).
- _Compositor_: `renderAt`/`render`/`offlineClips` take an `EffectHost` (`effects:`; new `abstract interface class EffectHost { AnimationView apply(String clipId, EffectRef ref, int frameIndex, AnimationView input) }`, `EffectHostException(EffectHostErrorKind.unavailable | failed)`). While an effect clip is active the picture accumulated by the tracks below (and the earlier layers of its track) is handed to the host at the grid frame of the clip's source time (`frameIndexAt(framerate, sourceTime)`), and the result is composited back over the input with the clip's blend mode at the usual alpha factor (opacity × fades × track opacity × transition weight) inside the clip's region only; elsewhere, without a host or after an `EffectHostException` the input passes through. New `OfflineReason.effectUnavailable` / `effectFailed`, reported by `render` (host failures) and `offlineClips` (no host).
- Edits: `addClip` accepts effect refs without a _SourceInfo_; `setGeneratorBindings`/`setGeneratorSeed` work on effect refs too (aliases `setEffectBindings`/`setEffectSeed`); `dragClipEdge`, `setClipSpeed`/`setClipLoop`, `reanchorGeneratorClips`/`audioOriginFor` and `applyAttributes` (bindings between clips of the same effect; the mask flag is skipped for effect targets) treat generator and effect clips alike.
- `.icproj` version 2: a clip `source` may be `{"type": "effect", "id", "version", "seed", "lengthUs", "audioOriginUs"?, "params"}`, salvaged like a generator source; `"mask": true` on an effect clip is dropped with a `defaultedValue` problem.

## 0.5.0

- Timeline craft. _Clip_ gains `reverse` (plays the trimmed range backwards), `pingPong` (a looping clip alternates direction every pass; only with a loop, dropped when the loop is removed) and `label` (_ClipLabel_ `none`/`red`/`orange`/`yellow`/`green`/`blue`/`purple`, no effect on the render); `sourceTimeAt`/`extendedSourceTimeAt` honour them. _VisualTrack_ gains `solo` (while any track is solo only the solo tracks render: `Composition.hasSolo`, `isTrackAudible`). _Marker_ gains `color` (a _ClipLabel_). _Composition_ gains `loopRange` (_LoopRange_ `{start, end}`, the in/out points).
- Edits: `setClipReverse`, `setClipPingPong`, `setClipLabel` (+ the same on `setClipProps`), `updateTrack(solo:)`, `updateMarker(color:)`, `moveMarker`, `setLoopRange`; multi-clip, all-or-nothing operations `moveClips(ids, delta, trackShift:)` (delta clamped at the timeline start, track shift clamped to the existing tracks, transitions between moved clips kept) and `nudgeClips`, `removeClips`, `rippleDelete(clipId)` (later clips of the track move left by the clip duration), `pasteClips(templates, at, trackId, newClipIds:)` (relative offsets kept, `at` clamped to 0) and `applyAttributes(targetIds, from, …)` (blend, opacity, fades clamped to each target, region fitted, mask, optionally the label, and the bindings of a generator target of the same generator). A move or paste that would overlap is refused with the new `CompositionErrorKind.overlap`.
- _Compositor_: `render(range:)` exports the grid frames covering a _LoopRange_ (frame-identical to the preview); solo tracks honoured by `renderAt`, `render` and `offlineClips`.
- `.icproj` version 2 adds, each omitted at its default: clip `reverse`, `pingPong`, `label`, track `solo`, marker `color` and the composition `loopRange: {startUs, endUs}`; unreadable values fall back to the defaults with a `defaultedValue` problem. Documents without them keep their version 1 bytes.

## 0.4.0

- _PixelMask_: a bit set over the target's icicle pixels (column-major `x · yCount + y`) followed by its radio panel pixels, with the dimensions it was made for: `PixelMask.full(target)` / `.empty(target)`, `contains(pixel)`, `containsPanelPixel(panel, led)` (1-based panel), `withPixel`, `withPanelPixel`, `withPixels`, `inverted()`, `fitTo(target)` (keeps overlapping pixels by position, new pixels included), `coveredCount`, `isFull`, `isEmpty`, `fits(target)`.
- _Region_ gains `pixels: PixelMask?` (`null` = every pixel), intersected with `columns` and `panels` by the compositor (`affectsIciclePixel`, `affectsPanelPixel`, `hasPixelMask`); `isClassic` is `false` with a mask; `normalized(target)` re-dimensions the mask (a full one is dropped).
- Mask layers: `Clip.isMask` (default `false`). A mask clip is not drawn; at every pixel the luminance (`Color.computeLuminance`, linear) of its composited output (its opacity, fades, transition weight and region — outside the region the lower tracks stay untouched) multiplies the color the tracks below (and the earlier layers of its own track) have accumulated so far, a Premiere-like track matte. The tracks above are unaffected. `setClipMask(clipId, isMask)`, `setClipProps(isMask:)`.
- `.icproj` version 2: a region may carry `"pixels": {"x", "y", "panels", "panelPixels", "bits": base64}` (icicle pixels first, then panel pixels, little-endian bits; unreadable → every pixel with a `defaultedValue` problem, other dimensions fitted with a `clampedValue` problem) and a clip `"mask": true` (omitted when false). Either makes the document version 2; version 1 files are still written byte-identically.

## 0.3.0

- _Region_ is a value class instead of an enum: `icicles` (bool), `columns` (an inclusive 0-based _ColumnRange_, `null` = every column) and `panels` (sealed _RegionPanels_: `all()`, `none()`, `some({1-based indices})`). The old values are `Region.all()`, `Region.iciclesOnly()` and `Region.panelsOnly()`; `affectsPixel(x)`, `affectsPanel(index)`, `isEmpty`, `isClassic`, `normalized(target)`.
- _Compositor_ masks per icicle column and per radio panel.
- `.icproj`: a clip `region` is `{"icicles", "columns": [first, last]?, "panels": "all" | "none" | [indices]}` in version 2; the version 1 strings are still read, and a composition with classic regions only (and no generator clips) is still written as version 1, byte-identical to before. Unreadable regions fall back to `Region.all()` with a problem; out-of-range columns/panels are fitted to the target (`clampedValue`).

## 0.2.0

- Depends on _icicles_generators_ (path dependency for now). _Tempo_, `frameIndexAt` and `frameCountFor` now come from it and are re-exported unchanged.
- _SourceRef_ is sealed: _AnimationFileRef_ (the former _SourceRef_: `path`, `contentHash`) and _GeneratorRef_ (`generatorId`, `generatorVersion`, `bindings`, `seed`, `length`, `audioOrigin`).
- Generator clips: `addClip` needs no _SourceInfo_ for a _GeneratorRef_; `setGeneratorBindings`, `setGeneratorSeed`; `speed` is always 1 and they never loop (`setClipSpeed`/`setClipLoop` refuse with `invalidValue`); dragging the end edge grows or shrinks the generator `length` (stretch acts like trim, at most `maxBakeLength`). `audioOrigin` is kept at `clip.start − sourceIn − audio.offset` by every edit (`reanchorGeneratorClips`, `audioOriginFor`).
- _OfflineReason_ gains `generatorUnavailable` and `generatorFailed` for the application to report.
- `.icproj` version 2: a clip `source` carries a `type` (`file` or `generator`). Compositions without generator clips are still written as version 1, byte-identical to before; the codec reads both. New problem kind `droppedBinding`.

## 0.1.0

- Initial release, depends on _icicles_animation_dart_ `v3.2.0`.
- Composition model: _Composition_, _OutputSpec_, _VisualTrack_, _Clip_ (trim, speed, loop, blend, opacity, fades, region), _Transition_, _SourceRef_, _AudioRef_, _Tempo_, _Marker_.
- Pure edit operations (_CompositionEdits_) with typed _CompositionException_ errors, no same-track overlap, layout check, and _Snapper_.
- `.icproj` codec (version 1) with per-element salvage and a stable encoder.
- _Compositor_: `renderAt` for the preview and `render` for the export on the drift-free frame grid, with offline-source and firmware-delay warnings.

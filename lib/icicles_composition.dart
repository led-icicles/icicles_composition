/// Timeline compositions of icicles animations: the composition model, pure
/// edit operations, the `.icproj` project codec and the compositor that
/// renders a composition into a single `.anim` animation.
///
/// Pure Dart: no Flutter and no `dart:io`; file access is left to the
/// application.
library;

export 'package:icicles_generators/icicles_generators.dart' show Tempo, frameCountFor, frameIndexAt;

export 'src/codec/drawing_pixels_codec.dart';
export 'src/codec/icproj_codec.dart';
export 'src/edit/composition_edits.dart';
export 'src/edit/composition_exception.dart';
export 'src/edit/snapper.dart';
export 'src/edit/source_info.dart';
export 'src/model/audio_track.dart';
export 'src/model/clip.dart';
export 'src/model/clip_label.dart';
export 'src/model/composition.dart';
export 'src/model/cue_track.dart';
export 'src/model/loop_range.dart';
export 'src/model/macro_def.dart';
export 'src/model/marker.dart';
export 'src/model/output_spec.dart';
export 'src/model/pixel_mask.dart';
export 'src/model/region.dart';
export 'src/model/show_settings.dart';
export 'src/model/source_ref.dart';
export 'src/model/stage_layout.dart';
export 'src/model/transition.dart';
export 'src/model/transition_fitting.dart';
export 'src/model/visual_track.dart';
export 'src/render/compositor.dart';
export 'src/render/effect_host.dart';
export 'src/render/render_result.dart';

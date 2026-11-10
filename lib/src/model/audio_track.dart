import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';

/// A piece of the music file placed on the timeline: the file range
/// `sourceIn..sourceOut` plays from timeline time [start] at speed 1.
///
/// [sourceOut] `null` means "to the end of the file": the model does not
/// know the file length, so an open-ended segment's end is resolved by the
/// application with the loaded length ([endFor]). Only the last segment of
/// a track may be open-ended.
class AudioSegment extends Equatable {
  /// Shortest segment an edit leaves behind.
  static const minDuration = Duration(milliseconds: 1);

  final String id;

  /// Timeline time the segment starts at (never negative).
  final Duration start;

  /// File time the segment starts at (never negative).
  final Duration sourceIn;

  /// File time the segment ends at (exclusive), `null` for the file end.
  final Duration? sourceOut;

  AudioSegment({required this.id, required this.start, this.sourceIn = Duration.zero, this.sourceOut}) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (start.isNegative) throw ArgumentError.value(start, 'start', 'Must not be negative.');
    if (sourceIn.isNegative) throw ArgumentError.value(sourceIn, 'sourceIn', 'Must not be negative.');
    final out = sourceOut;
    if (out != null && out - sourceIn < minDuration) {
      throw ArgumentError.value(out, 'sourceOut', 'Must be at least $minDuration after sourceIn.');
    }
  }

  /// Whether the segment plays to the end of the file ([sourceOut] `null`).
  bool get isOpenEnded => sourceOut == null;

  /// Timeline time at which file time 0 would play under this segment's
  /// mapping: `start − sourceIn`. Song time = timeline time − offset.
  Duration get offset => start - sourceIn;

  /// Length on the timeline; `null` while open-ended.
  Duration? get duration => sourceOut == null ? null : sourceOut! - sourceIn;

  /// Timeline end; `null` while open-ended.
  Duration? get end => duration == null ? null : start + duration!;

  /// [sourceOut] resolved against the file length [sourceLength] (an explicit
  /// end past the file is cut at the file end).
  Duration sourceOutFor(Duration sourceLength) {
    final out = sourceOut;
    return out == null || out > sourceLength ? sourceLength : out;
  }

  /// Timeline end resolved against the file length.
  Duration endFor(Duration sourceLength) => start + sourceOutFor(sourceLength) - sourceIn;

  /// Whether timeline [time] lies inside the segment (`start <= time < end`);
  /// an open-ended segment is unbounded without [sourceLength].
  bool contains(Duration time, {Duration? sourceLength}) {
    if (time < start) return false;
    final end = sourceLength == null ? this.end : endFor(sourceLength);
    return end == null || time < end;
  }

  /// File time playing at timeline [time] under this segment's mapping.
  Duration sourceTimeAt(Duration time) => time - offset;

  /// A copy with the given fields replaced; [openEnded] clears [sourceOut].
  AudioSegment copyWith(
          {String? id, Duration? start, Duration? sourceIn, Duration? sourceOut, bool openEnded = false}) =>
      AudioSegment(
        id: id ?? this.id,
        start: start ?? this.start,
        sourceIn: sourceIn ?? this.sourceIn,
        sourceOut: openEnded ? null : (sourceOut ?? this.sourceOut),
      );

  @override
  List<Object?> get props => [id, start, sourceIn, sourceOut];
}

/// The music track of a composition: one file played as sorted,
/// non-overlapping [segments] (see [AudioSegment]).
class AudioTrack extends Equatable {
  /// Highest allowed [gain].
  static const maxGain = 4.0;

  /// Path of the audio file, relative to the project file by convention.
  final String path;

  /// Linear volume factor in `[0, maxGain]`; `1` keeps the file volume.
  final double gain;

  /// Sorted by [AudioSegment.start]; never empty.
  final List<AudioSegment> segments;

  /// Throws an [ArgumentError] for an empty path, a gain out of range, no
  /// segments, repeated segment ids, overlapping segments or an open-ended
  /// segment that is not the last one.
  AudioTrack({required this.path, this.gain = 1.0, required List<AudioSegment> segments})
      : segments = List.unmodifiable(segments.sorted((a, b) => a.start.compareTo(b.start))) {
    if (path.isEmpty) throw ArgumentError.value(path, 'path', 'Must not be empty.');
    if (!gain.isFinite || gain < 0 || gain > maxGain) {
      throw ArgumentError.value(gain, 'gain', 'Must be in [0, $maxGain].');
    }
    if (this.segments.isEmpty) throw ArgumentError.value(segments, 'segments', 'Must not be empty.');
    final ids = <String>{};
    for (final (index, segment) in this.segments.indexed) {
      if (!ids.add(segment.id)) throw ArgumentError('Duplicate audio segment id "${segment.id}".');
      if (index == this.segments.length - 1) break;
      final end = segment.end;
      if (end == null) throw ArgumentError('Only the last audio segment may be open-ended ("${segment.id}").');
      if (end > this.segments[index + 1].start) {
        throw ArgumentError('Audio segments "${segment.id}" and "${this.segments[index + 1].id}" overlap.');
      }
    }
  }

  /// One open-ended segment of the whole file starting at timeline
  /// [offset] (a negative offset skips the beginning of the file).
  factory AudioTrack.single(
          {required String path, double gain = 1.0, Duration offset = Duration.zero, String id = 'a1'}) =>
      AudioTrack(
        path: path,
        gain: gain,
        segments: [
          AudioSegment(
            id: id,
            start: offset.isNegative ? Duration.zero : offset,
            sourceIn: offset.isNegative ? -offset : Duration.zero,
          ),
        ],
      );

  AudioSegment get first => segments.first;

  AudioSegment get last => segments.last;

  /// Whether the track is one open-ended segment of the whole file, i.e.
  /// the plain soundtrack at [offset] it started as.
  bool get isSingleWhole =>
      segments.length == 1 && first.isOpenEnded && (first.start == Duration.zero || first.sourceIn == Duration.zero);

  /// [AudioSegment.offset] of the first segment: the mapping of the plain
  /// soundtrack (see [offsetAt] for the mapping at a time).
  Duration get offset => first.offset;

  AudioSegment? segmentById(String id) => segments.firstWhereOrNull((segment) => segment.id == id);

  /// The segment playing at timeline [time], or `null` in a gap. An
  /// open-ended last segment is unbounded without [sourceLength].
  AudioSegment? segmentAt(Duration time, {Duration? sourceLength}) =>
      segments.firstWhereOrNull((segment) => segment.contains(time, sourceLength: sourceLength));

  /// The segment whose mapping applies at timeline [time]: the one playing
  /// there, else the last segment starting before [time], else the first.
  /// Audio-bound generator clips and the beat grid use it outside the
  /// segments, so a clip in a gap keeps following the preceding music.
  AudioSegment segmentFor(Duration time, {Duration? sourceLength}) =>
      segmentAt(time, sourceLength: sourceLength) ??
      segments.lastWhereOrNull((segment) => segment.start <= time) ??
      first;

  /// [AudioSegment.offset] of [segmentFor] at [time]: song time there is
  /// `time − offsetAt(time)`.
  Duration offsetAt(Duration time, {Duration? sourceLength}) => segmentFor(time, sourceLength: sourceLength).offset;

  /// Timeline end of the last segment; `null` while it is open-ended.
  Duration? get end => last.end;

  /// Timeline end of the last segment resolved against the file length.
  Duration endFor(Duration sourceLength) => last.endFor(sourceLength);

  AudioTrack copyWith({String? path, double? gain, List<AudioSegment>? segments}) =>
      AudioTrack(path: path ?? this.path, gain: gain ?? this.gain, segments: segments ?? this.segments);

  @override
  List<Object?> get props => [path, gain, segments];
}

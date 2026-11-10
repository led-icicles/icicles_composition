import 'package:equatable/equatable.dart';

/// The in/out points of a composition: a span of the timeline the
/// application can play in a loop and export on its own.
class LoopRange extends Equatable {
  /// Timeline time of the in point, never negative.
  final Duration start;

  /// Timeline time of the out point (exclusive), after [start].
  final Duration end;

  LoopRange({required this.start, required this.end}) {
    if (start.isNegative) throw ArgumentError.value(start, 'start', 'Must not be negative.');
    if (end <= start) throw ArgumentError.value(end, 'end', 'Must be after start ($start).');
  }

  Duration get duration => end - start;

  /// Whether [time] is in `[start, end)`.
  bool contains(Duration time) => time >= start && time < end;

  LoopRange copyWith({Duration? start, Duration? end}) => LoopRange(start: start ?? this.start, end: end ?? this.end);

  @override
  List<Object?> get props => [start, end];
}

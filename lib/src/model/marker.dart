import 'package:equatable/equatable.dart';

import 'clip_label.dart';

/// A named point on the timeline.
class Marker extends Equatable {
  final String id;

  /// Timeline time, never negative.
  final Duration at;

  final String label;

  /// Color of the flag on the ruler.
  final ClipLabel color;

  Marker({required this.id, required this.at, this.label = '', this.color = ClipLabel.none}) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (at.isNegative) throw ArgumentError.value(at, 'at', 'Must not be negative.');
  }

  Marker copyWith({Duration? at, String? label, ClipLabel? color}) =>
      Marker(id: id, at: at ?? this.at, label: label ?? this.label, color: color ?? this.color);

  @override
  List<Object?> get props => [id, at, label, color];
}

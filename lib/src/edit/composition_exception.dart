/// Why an edit operation or a render was refused.
enum CompositionErrorKind {
  trackNotFound,
  clipNotFound,
  transitionNotFound,
  markerNotFound,
  macroNotFound,
  audioSegmentNotFound,

  /// The id is already used in the composition.
  duplicateId,

  /// The clips of a locked track cannot change.
  trackLocked,

  /// The source does not have the pixels and radio panels layout of the
  /// composition target.
  layoutMismatch,

  /// The split point is not inside the clip.
  invalidSplit,

  /// The clips of a transition are not adjacent on one track.
  notAdjacent,

  /// There is no room for a transition between the clips.
  noRoom,

  /// A value is out of its range.
  invalidValue,

  /// Clips of an all-or-nothing operation would overlap other clips of
  /// their track (or each other); nothing changed.
  overlap,

  /// There is nothing to render.
  emptyComposition,
}

/// A refused edit operation or render.
class CompositionException implements Exception {
  final CompositionErrorKind kind;

  /// Technical description, not meant for end users.
  final String message;

  const CompositionException(this.kind, this.message);

  @override
  String toString() => 'CompositionException(${kind.name}): $message';
}

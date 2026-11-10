import 'clip.dart';
import 'transition.dart';

/// Largest gap between two clips that still counts as adjacent (a cut).
const adjacencyTolerance = Duration(milliseconds: 1);

/// Why [fitTransitions] changed or dropped a transition.
enum TransitionIssueKind {
  /// A referenced clip is not on the track.
  missingClip,

  /// The incoming clip does not directly follow the outgoing one.
  notAdjacent,

  /// Another transition already joins the same clips, or uses the same id.
  duplicate,

  /// The duration was shortened to the limit.
  clamped,

  /// No room is left for the transition.
  noRoom,
}

/// A change [fitTransitions] made.
class TransitionIssue {
  final Transition transition;
  final TransitionIssueKind kind;

  /// Whether the transition was removed (otherwise it was [TransitionIssueKind.clamped]).
  bool get dropped => kind != TransitionIssueKind.clamped;

  const TransitionIssue(this.transition, this.kind);

  @override
  String toString() => 'TransitionIssue(${transition.id}, ${kind.name})';
}

/// Fits [transitions] to [clips] (sorted by start, no overlap).
///
/// A transition is kept only between a clip and the next one, when they
/// touch (within [adjacencyTolerance]). Its duration is at most
/// `min(from.duration, to.duration)`, and its parts inside each clip must
/// not overlap the clip's other transition: transitions earlier on the
/// track keep their length, later ones are shortened.
({List<Transition> kept, List<TransitionIssue> issues}) fitTransitions(
  List<Clip> clips,
  List<Transition> transitions,
) {
  final position = {for (final (index, clip) in clips.indexed) clip.id: index};
  final issues = <TransitionIssue>[];
  final candidates = <(int, Transition)>[];
  final seenIds = <String>{};
  final seenFrom = <String>{};
  for (final transition in transitions) {
    final from = position[transition.fromClipId];
    final to = position[transition.toClipId];
    if (from == null || to == null) {
      issues.add(TransitionIssue(transition, TransitionIssueKind.missingClip));
    } else if (to != from + 1 || (clips[to].start - clips[from].end).abs() > adjacencyTolerance) {
      issues.add(TransitionIssue(transition, TransitionIssueKind.notAdjacent));
    } else if (!seenIds.add(transition.id) || !seenFrom.add(transition.fromClipId)) {
      issues.add(TransitionIssue(transition, TransitionIssueKind.duplicate));
    } else {
      candidates.add((from, transition));
    }
  }
  candidates.sort((a, b) => a.$1.compareTo(b.$1));

  final kept = <Transition>[];
  final reservedAfter = <String, Duration>{};
  for (final (from, transition) in candidates) {
    final a = clips[from];
    final b = clips[from + 1];
    final aFree = (a.duration - (reservedAfter[a.id] ?? Duration.zero)).inMicroseconds;
    final bFree = b.duration.inMicroseconds;
    var max = a.duration < b.duration ? a.duration.inMicroseconds : b.duration.inMicroseconds;
    switch (transition.alignment) {
      case TransitionAlignment.center:
        max = _min(max, _min(2 * aFree, 2 * bFree));
      case TransitionAlignment.startAtCut:
        max = _min(max, bFree);
      case TransitionAlignment.endAtCut:
        max = _min(max, aFree);
    }
    if (max <= 0) {
      issues.add(TransitionIssue(transition, TransitionIssueKind.noRoom));
      continue;
    }
    var fitted = transition;
    if (transition.duration.inMicroseconds > max) {
      fitted = transition.copyWith(duration: Duration(microseconds: max));
      issues.add(TransitionIssue(transition, TransitionIssueKind.clamped));
    }
    reservedAfter[b.id] = fitted.partAfter;
    kept.add(fitted);
  }
  return (kept: kept, issues: issues);
}

int _min(int a, int b) => a < b ? a : b;

/// How long a transition holds edge frames (the "frozen frames" hint)
/// because a clip has no material there: [Transition.partAfter] needs
/// material after the outgoing clip's `sourceOut`, [Transition.partBefore]
/// material before the incoming clip's `sourceIn`. Looping clips always
/// have material. The source lengths are those of one source pass.
({Duration outgoing, Duration incoming}) frozenTransitionParts(
  Transition transition, {
  required Clip from,
  required Clip to,
  required Duration fromSourceLength,
  required Duration toSourceLength,
}) {
  var outgoing = Duration.zero;
  if (!from.isLooping) {
    final needed = to.start + transition.partAfter - from.end;
    final remaining = fromSourceLength - from.sourceOut;
    final available = Duration(
      microseconds: remaining.isNegative ? 0 : (remaining.inMicroseconds / from.speed).floor(),
    );
    if (needed > available) outgoing = needed - available;
  }
  var incoming = Duration.zero;
  if (!to.isLooping) {
    final needed = transition.partBefore;
    final available = Duration(microseconds: (to.sourceIn.inMicroseconds / to.speed).floor());
    if (needed > available) incoming = needed - available;
  }
  return (outgoing: outgoing, incoming: incoming);
}

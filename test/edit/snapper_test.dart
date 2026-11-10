import 'package:icicles_composition/icicles_composition.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  final composition = testComposition(tracks: [
    VisualTrack(id: 't', clips: [
      testClip('a', sourceOut: s(1)),
      testClip('b', start: s(3), sourceOut: s(1)),
    ]),
  ]).addMarker(Marker(id: 'm', at: ms(2200))).setTempo(Tempo(bpm: 60, firstBeatOffset: ms(500)));

  test('snaps to the nearest target within the tolerance', () {
    final snapper = Snapper(tolerance: ms(100));
    expect(snapper.snap(composition, ms(1050)), SnapResult(s(1), SnapTargetKind.clipEdge));
    expect(snapper.snap(composition, ms(2150)), SnapResult(ms(2200), SnapTargetKind.marker));
    expect(snapper.snap(composition, ms(1560)), SnapResult(ms(1500), SnapTargetKind.beat));
    expect(snapper.snap(composition, ms(2700)), isNull);
    expect(snapper.snap(composition, ms(2700), playheadAt: ms(2750)), SnapResult(ms(2750), SnapTargetKind.playhead));
  });

  test('prefers the playhead, then clip edges, markers and beats on a tie', () {
    final snapper = Snapper(tolerance: ms(100));
    expect(snapper.snap(composition, ms(1050), playheadAt: ms(1100)), SnapResult(ms(1100), SnapTargetKind.playhead));
    expect(snapper.snap(composition, ms(1050), playheadAt: ms(1101)), SnapResult(s(1), SnapTargetKind.clipEdge));
    expect(snapper.snap(composition, ms(1000), playheadAt: s(1)), SnapResult(s(1), SnapTargetKind.playhead));
  });

  test('ignores the dragged clips and disabled kinds', () {
    expect(Snapper(tolerance: ms(100)).snap(composition, ms(1050), ignoreClipIds: {'a'}), isNull);
    expect(Snapper(tolerance: ms(100), beats: false).snap(composition, ms(1560)), isNull);
    expect(Snapper(tolerance: ms(100), clipEdges: false).snap(composition, ms(1050)), isNull);
  });

  test('snapSpan snaps the nearer edge of a moving clip', () {
    final snapper = Snapper(tolerance: ms(100), beats: false);
    final byEnd = snapper.snapSpan(composition, ms(1230), s(1), ignoreClipIds: {'b'});
    expect(byEnd, SpanSnapResult(start: ms(1200), snap: SnapResult(ms(2200), SnapTargetKind.marker), snappedEnd: true));
    final byStart = snapper.snapSpan(composition, ms(1020), ms(500));
    expect(byStart?.start, s(1));
    expect(byStart?.snappedEnd, isFalse);
  });
}

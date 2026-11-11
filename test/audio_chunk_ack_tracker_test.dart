import 'package:flutter_test/flutter_test.dart';
import 'package:salamasphere_mobile/services/audio_chunk_ack_tracker.dart';

void main() {
  test('acknowledges chunk zero immediately', () {
    final tracker = AudioChunkAckTracker();

    expect(tracker.recordReceived(0), 0);
    expect(tracker.highestContiguousSequence, 0);
    expect(tracker.receivedCount, 1);
  });

  test('holds cumulative ACK until a missing chunk arrives', () {
    final tracker = AudioChunkAckTracker();

    expect(tracker.recordReceived(1), isNull);
    expect(tracker.highestContiguousSequence, -1);
    expect(tracker.recordReceived(0), 1);
    expect(tracker.highestContiguousSequence, 1);
  });

  test('repeats the cumulative ACK for a duplicate chunk', () {
    final tracker = AudioChunkAckTracker();

    expect(tracker.recordReceived(0), 0);
    expect(tracker.recordReceived(0), 0);
    expect(tracker.receivedCount, 1);
  });
}

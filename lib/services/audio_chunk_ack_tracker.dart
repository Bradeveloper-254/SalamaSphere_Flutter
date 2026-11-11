class AudioChunkAckTracker {
  final Set<int> _receivedSequences = <int>{};
  int highestContiguousSequence = -1;

  int get receivedCount => _receivedSequences.length;

  int? recordReceived(int sequence) {
    final duplicate = !_receivedSequences.add(sequence);
    final previousHighest = highestContiguousSequence;

    while (_receivedSequences.contains(highestContiguousSequence + 1)) {
      highestContiguousSequence++;
    }

    if (highestContiguousSequence > previousHighest ||
        (duplicate && highestContiguousSequence >= 0)) {
      return highestContiguousSequence;
    }
    return null;
  }
}

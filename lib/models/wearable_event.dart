class WearableEvent {
  final String eventId;
  final String deviceIdentifier;
  final String eventType;
  final DateTime timestamp;
  final int protocolVersion;
  final String? recordingStatus;

  const WearableEvent({
    required this.eventId,
    required this.deviceIdentifier,
    required this.eventType,
    required this.timestamp,
    this.protocolVersion = 1,
    this.recordingStatus,
  });

  factory WearableEvent.fromJson(Map<String, dynamic> json) {
    final eventId = json['event_id'];
    final deviceIdentifier = json['device_identifier'] ?? json['device_id'];
    final eventType = json['event_type'];
    final rawTimestamp = json['timestamp'];
    final rawProtocolVersion = json['protocol_version'] ?? 1;
    final rawRecordingStatus = json['recording_status'];

    if (eventId is! String ||
        eventId.isEmpty ||
        deviceIdentifier is! String ||
        deviceIdentifier.isEmpty ||
        eventType is! String ||
        eventType.isEmpty ||
        rawProtocolVersion is! int ||
        (rawTimestamp != null && rawTimestamp is! String) ||
        (rawRecordingStatus != null && rawRecordingStatus is! String)) {
      throw const FormatException('Invalid wearable event payload.');
    }

    final parsedTimestamp = rawTimestamp == null
        ? DateTime.now().toUtc()
        : DateTime.tryParse(rawTimestamp as String);

    if (parsedTimestamp == null) {
      throw const FormatException('Invalid wearable event timestamp.');
    }

    return WearableEvent(
      eventId: eventId,
      deviceIdentifier: deviceIdentifier,
      eventType: eventType,
      timestamp: parsedTimestamp.toUtc(),
      protocolVersion: rawProtocolVersion,
      recordingStatus: rawRecordingStatus as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'event_id': eventId,
      'device_identifier': deviceIdentifier,
      'event_type': eventType,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'protocol_version': protocolVersion,
      if (recordingStatus != null) 'recording_status': recordingStatus,
    };
  }
}

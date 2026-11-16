/// SOS event reported by a SalamaSphere wearable over BLE.
class WearableEvent {
  final String eventId;
  final String deviceIdentifier;
  final String eventType;
  final DateTime timestamp;
  final int protocolVersion;
  final bool callRequested;
  final String? recordingStatus;

  const WearableEvent({
    required this.eventId,
    required this.deviceIdentifier,
    required this.eventType,
    required this.timestamp,
    this.protocolVersion = 1,
    this.callRequested = false,
    this.recordingStatus,
  });

  factory WearableEvent.fromJson(Map<String, dynamic> json) {
    final eventId = json['event_id']?.toString().trim() ?? '';
    final deviceIdentifier = json['device_identifier']?.toString().trim() ?? '';
    final eventType = json['event_type']?.toString().trim() ?? '';
    final timestampValue = json['timestamp']?.toString().trim() ?? '';
    final timestamp = DateTime.tryParse(timestampValue);

    if (eventId.isEmpty ||
        deviceIdentifier.isEmpty ||
        eventType.isEmpty ||
        timestamp == null) {
      throw const FormatException('SOS event is missing required fields.');
    }

    final version = json['protocol_version'];
    return WearableEvent(
      eventId: eventId,
      deviceIdentifier: deviceIdentifier,
      eventType: eventType,
      timestamp: timestamp.toUtc(),
      protocolVersion: version is int ? version : int.tryParse('$version') ?? 1,
      callRequested: json['call_requested'] == true ||
          json['call_action']?.toString().toUpperCase() == 'CALL',
      recordingStatus: json['recording_status']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'device_identifier': deviceIdentifier,
    'event_type': eventType,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'protocol_version': protocolVersion,
    'call_requested': callRequested,
    if (recordingStatus != null) 'recording_status': recordingStatus,
  };
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:salamasphere_mobile/models/wearable_event.dart';
import 'package:salamasphere_mobile/services/ble_service.dart';

void main() {
  late BleService bleService;

  setUp(() {
    bleService = BleService();
  });

  test('Parses a valid SOS event', () {
    final payload = {
      'event_id': 'event-example-001',
      'device_identifier': 'SALAMA-DEVICE-001',
      'event_type': 'SOS',
      'timestamp': '2026-10-16T12:00:00Z',
      'protocol_version': 1,
    };

    final bytes = utf8.encode(jsonEncode(payload));

    final WearableEvent event = bleService.parseEvent(bytes);

    expect(event.eventId, 'event-example-001');
    expect(event.deviceIdentifier, 'SALAMA-DEVICE-001');
    expect(event.eventType, 'SOS');
    expect(event.protocolVersion, 1);
    expect(event.timestamp.isUtc, isTrue);
  });

  test('Rejects invalid JSON', () {
    final bytes = utf8.encode('{invalid-json');

    expect(() => bleService.parseEvent(bytes), throwsFormatException);
  });

  test('Rejects an event with missing required fields', () {
    final payload = {'event_id': 'event-example-002', 'event_type': 'SOS'};

    final bytes = utf8.encode(jsonEncode(payload));

    expect(() => bleService.parseEvent(bytes), throwsFormatException);
  });

  test('Converts an event to JSON', () {
    final event = WearableEvent(
      eventId: 'event-example-003',
      deviceIdentifier: 'SALAMA-DEVICE-001',
      eventType: 'SOS',
      timestamp: DateTime.utc(2026, 10, 16, 12),
      callRequested: true,
    );

    final json = event.toJson();

    expect(json['event_id'], 'event-example-003');
    expect(json['device_identifier'], 'SALAMA-DEVICE-001');
    expect(json['event_type'], 'SOS');
    expect(json['call_requested'], isTrue);
    expect(WearableEvent.fromJson(json).callRequested, isTrue);
  });

  test('Uses the wearable transfer CRC-32 variant', () {
    expect(BleService.crc32(utf8.encode('123456789')), 0xcbf43926);
  });
}

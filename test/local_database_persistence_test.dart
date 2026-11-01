import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:salamasphere_mobile/services/local_database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }); 
  late Directory temporaryDirectory;
  late String databasePath;
  late LocalDatabaseService database;

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('salamasphere_test_');

    databasePath =
        '${temporaryDirectory.path}${Platform.pathSeparator}salamasphere_test.db';

    database = LocalDatabaseService.forTesting(databasePath);
  });

  tearDown(() async {
    await database.close();

    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<void> saveTestIncident() async {
    await database.saveIncident(
      clientEventId: 'test-event-001',
      deviceIdentifier: 'SALAMA-TEST-001',
      eventType: 'sos',
      capturedAt: DateTime.utc(2026, 10, 18, 8, 0),
      threatLevel: 'high',
      description: 'Synthetic incident for persistence testing.',
    );
  }

  test('saves an incident locally with pending status', () async {
    await saveTestIncident();

    final incidents = await database.getAllIncidents();

    expect(incidents, hasLength(1));
    expect(incidents.first['client_event_id'], 'test-event-001');
    expect(incidents.first['device_identifier'], 'SALAMA-TEST-001');
    expect(incidents.first['threat_level'], 'high');
    expect(incidents.first['sync_status'], 'pending');
    expect(incidents.first['server_incident_id'], isNull);
  });

  test('preserves an incident after closing and reopening SQLite', () async {
    await saveTestIncident();

    await database.close();

    database = LocalDatabaseService.forTesting(databasePath);

    final incidents = await database.getAllIncidents();

    expect(incidents, hasLength(1));
    expect(incidents.first['client_event_id'], 'test-event-001');
    expect(incidents.first['sync_status'], 'pending');
  });

  test('returns unsynchronized incidents for retry', () async {
    await saveTestIncident();

    final pending = await database.getPendingIncidents();

    expect(pending, hasLength(1));
    expect(pending.first['client_event_id'], 'test-event-001');
  });

  test('ignores a duplicate local event identifier', () async {
    await saveTestIncident();
    await saveTestIncident();

    final incidents = await database.getAllIncidents();

    expect(incidents, hasLength(1));
    expect(incidents.first['client_event_id'], 'test-event-001');
  });

  test('records a failed synchronization without deleting the incident',
      () async {
    await saveTestIncident();

    await database.markIncidentFailed(
      clientEventId: 'test-event-001',
      error: 'Simulated network failure',
    );

    final incidents = await database.getAllIncidents();
    final pending = await database.getPendingIncidents();

    expect(incidents, hasLength(1));
    expect(incidents.first['sync_status'], 'failed');
    expect(incidents.first['retry_count'], 1);
    expect(
      incidents.first['last_sync_error'],
      'Simulated network failure',
    );

    expect(pending, hasLength(1));
  });

  test('stores the server ID after synchronization succeeds', () async {
    await saveTestIncident();

    await database.markIncidentSynced(
      clientEventId: 'test-event-001',
      serverIncidentId: 'server-incident-123',
    );

    final incidents = await database.getAllIncidents();
    final pending = await database.getPendingIncidents();

    expect(incidents.first['sync_status'], 'synced');
    expect(
      incidents.first['server_incident_id'],
      'server-incident-123',
    );
    expect(pending, isEmpty);
  });
}
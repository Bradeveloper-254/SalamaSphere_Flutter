import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:salamasphere_mobile/services/local_database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService databaseService;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    databaseService = LocalDatabaseService.instance;

    // Initialize the database before each test.
    await databaseService.database;
  });

  test('Database opens successfully', () async {
    final db = await databaseService.database;

    expect(db.isOpen, isTrue);
  });

  test('Incident can be saved and retrieved', () async {
    final eventId = 'test-event-${DateTime.now().microsecondsSinceEpoch}';

    await databaseService.saveIncident(
      clientEventId: eventId,
      deviceIdentifier: 'SALAMA-TEST-DEVICE',
      eventType: 'SOS',
      capturedAt: DateTime.now().toUtc(),
    );

    final incidents = await databaseService.getAllIncidents();

    expect(
      incidents.any(
        (incident) => incident['client_event_id'] == eventId,
      ),
      isTrue,
    );
  });

  test('New incidents are marked pending', () async {
    final eventId = 'pending-event-${DateTime.now().microsecondsSinceEpoch}';

    await databaseService.saveIncident(
      clientEventId: eventId,
      deviceIdentifier: 'SALAMA-TEST-DEVICE',
      eventType: 'SOS',
      capturedAt: DateTime.now().toUtc(),
    );

    final pending = await databaseService.getPendingIncidents();

    expect(
      pending.any(
        (incident) => incident['client_event_id'] == eventId,
      ),
      isTrue,
    );
  });

  test('Duplicate event IDs do not create duplicate incidents', () async {
    final eventId = 'duplicate-event-${DateTime.now().microsecondsSinceEpoch}';

    Future<void> save() async {
      await databaseService.saveIncident(
        clientEventId: eventId,
        deviceIdentifier: 'SALAMA-TEST-DEVICE',
        eventType: 'SOS',
        capturedAt: DateTime.now().toUtc(),
      );
    }

    await save();
    await save();

    final incidents = await databaseService.getAllIncidents();

    final matching = incidents
        .where((incident) => incident['client_event_id'] == eventId)
        .toList();

    expect(matching.length, 1);
  });
}
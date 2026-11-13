import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:salamasphere_mobile/services/incident_sync_service.dart';
import 'package:salamasphere_mobile/services/local_database_service.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory temporaryDirectory;
  late String databasePath;
  late LocalDatabaseService database;

  const eventId = 'offline-event-001';
  const deviceIdentifier = 'SALAMA-TEST-001';

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'salamasphere_sync_test_',
    );

    databasePath =
        '${temporaryDirectory.path}${Platform.pathSeparator}sync_test.db';

    database = LocalDatabaseService.forTesting(databasePath);
  });

  tearDown(() async {
    await database.close();

    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<void> saveIncident() async {
    await database.saveIncident(
      clientEventId: eventId,
      deviceIdentifier: deviceIdentifier,
      eventType: 'sos',
      capturedAt: DateTime.utc(2026, 10, 18, 8, 0),
      threatLevel: 'high',
      description: 'Synthetic offline recovery test incident.',
    );
  }

  test('offline incident remains stored and pending', () async {
    await saveIncident();

    var httpCalls = 0;

    final mockClient = MockClient((request) async {
      httpCalls++;

      return http.Response(jsonEncode({'id': 'server-001'}), 201);
    });

    final service = IncidentSyncService(
      database: database,
      client: mockClient,
      connectivityChecker: () async => [ConnectivityResult.none],
    );

    final result = await service.synchronizePendingIncidents(
      token: 'test-token',
    );

    final incidents = await database.getAllIncidents();
    final pending = await database.getPendingIncidents();

    expect(result, isFalse);
    expect(httpCalls, 0);
    expect(incidents, hasLength(1));
    expect(incidents.first['client_event_id'], eventId);
    expect(incidents.first['sync_status'], 'pending');
    expect(incidents.first['sync_state'], 'WAITING_FOR_NETWORK');
    expect(pending, hasLength(1));

    service.dispose();
  });

  test(
    'device claim errors are retained and stop incident submission',
    () async {
      await saveIncident();

      var incidentRequests = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/devices/register/') {
          return http.Response(
            jsonEncode({
              'detail':
                  'This wearable is already registered and cannot be claimed.',
            }),
            409,
          );
        }

        incidentRequests++;
        return http.Response(jsonEncode({'id': 'unexpected'}), 201);
      });

      final service = IncidentSyncService(
        database: database,
        client: mockClient,
        connectivityChecker: () async => [ConnectivityResult.wifi],
      );

      expect(
        await service.synchronizePendingIncidents(token: 'test-token'),
        isFalse,
      );
      expect(incidentRequests, 0);

      final incident = (await database.getAllIncidents()).single;
      expect(incident['sync_status'], 'failed');
      expect(
        incident['last_sync_error'],
        contains(
          'Wearable registration failed (HTTP 409): '
          'detail: This wearable is already registered',
        ),
      );

      service.dispose();
    },
  );

  test('incident recovers after connectivity returns', () async {
    await saveIncident();

    var online = false;
    var httpCalls = 0;

    final mockClient = MockClient((request) async {
      httpCalls++;

      expect(request.headers['authorization'], 'Token test-token');

      if (request.url.path == '/api/devices/register/') {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['device_identifier'], deviceIdentifier);
        return http.Response(jsonEncode({'id': 'device-001'}), 201);
      }

      final payload = jsonDecode(request.body) as Map<String, dynamic>;

      expect(payload['client_event_id'], eventId);
      expect(payload['device_identifier'], deviceIdentifier);
      expect(request.url.path, '/api/incidents/');

      return http.Response(
        jsonEncode({'id': 'server-002'}),
        201,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = IncidentSyncService(
      database: database,
      client: mockClient,
      connectivityChecker: () async =>
          online ? [ConnectivityResult.wifi] : [ConnectivityResult.none],
    );

    // First attempt: offline.
    final offlineResult = await service.synchronizePendingIncidents(
      token: 'test-token',
    );

    expect(offlineResult, isFalse);
    expect(httpCalls, 0);

    var incidents = await database.getAllIncidents();

    expect(incidents.single['sync_status'], 'pending');

    // Simulate reconnection.
    online = true;

    final onlineResult = await service.synchronizePendingIncidents(
      token: 'test-token',
    );

    expect(onlineResult, isTrue);
    expect(httpCalls, 2);

    incidents = await database.getAllIncidents();

    expect(incidents, hasLength(1));
    expect(incidents.single['sync_status'], 'synced');
    expect(incidents.single['server_incident_id'], 'server-002');
    expect(incidents.single['sync_state'], 'SERVER_CONFIRMED');
    expect(incidents.single['metadata_ack_status'], 'received');

    final pending = await database.getPendingIncidents();

    expect(pending, isEmpty);

    service.dispose();
  });

  test('failed upload can be retried successfully', () async {
    await saveIncident();

    var incidentAttempts = 0;
    final submittedEventIds = <String>[];

    final mockClient = MockClient((request) async {
      if (request.url.path == '/api/devices/register/') {
        return http.Response(jsonEncode({'id': 'device-001'}), 201);
      }

      incidentAttempts++;

      final payload = jsonDecode(request.body) as Map<String, dynamic>;

      submittedEventIds.add(payload['client_event_id'] as String);

      if (incidentAttempts == 1) {
        return http.Response(
          jsonEncode({'detail': 'Temporarily unavailable'}),
          503,
        );
      }

      return http.Response(
        jsonEncode({'id': 'server-003'}),
        201,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = IncidentSyncService(
      database: database,
      client: mockClient,
      connectivityChecker: () async => [ConnectivityResult.wifi],
    );

    // Attempt 1: the server returns an error.
    final firstResult = await service.synchronizePendingIncidents(
      token: 'test-token',
    );

    expect(firstResult, isFalse);

    var incidents = await database.getAllIncidents();

    expect(incidents.single['sync_status'], 'failed');
    expect(incidents.single['retry_count'], 1);
    expect(
      incidents.single['last_sync_error'],
      'HTTP 503: detail: Temporarily unavailable',
    );

    // Attempt 2: the server accepts the same event.
    final secondResult = await service.synchronizePendingIncidents(
      token: 'test-token',
    );

    expect(secondResult, isTrue);
    expect(incidentAttempts, 2);

    // The stable identifier must not change between attempts.
    expect(submittedEventIds, [eventId, eventId]);

    incidents = await database.getAllIncidents();

    expect(incidents, hasLength(1));
    expect(incidents.single['sync_status'], 'synced');
    expect(incidents.single['server_incident_id'], 'server-003');

    service.dispose();
  });

  test('metadata and audio acknowledgements complete independently', () async {
    await saveIncident();
    await database.saveIncidentAudio(
      clientEventId: eventId,
      bytes: <int>[1, 2, 3, 4],
      fileName: 'sample.wav',
      mimeType: 'audio/wav',
    );

    final client = MockClient((request) async {
      if (request.url.path == '/api/devices/register/') {
        return http.Response(jsonEncode({'id': 'device-audio-001'}), 201);
      }

      if (request.url.path.endsWith('/incidents/')) {
        return http.Response(
          jsonEncode({
            'id': 'server-audio-001',
            'status': 'received',
            'acknowledgements': {
              'metadata_received': true,
              'audio_received': false,
              'evidence_hash_calculated': false,
              'notification_submitted': false,
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });

    final service = IncidentSyncService(
      database: database,
      client: client,
      connectivityChecker: () async => [ConnectivityResult.wifi],
    );

    expect(
      await service.synchronizePendingIncidents(token: 'test-token'),
      isTrue,
    );
    var incident = (await database.getAllIncidents()).single;
    expect(incident['sync_state'], 'SERVER_CONFIRMED');
    expect(incident['metadata_ack_status'], 'received');
    expect(incident['audio_ack_status'], 'pending');

    await service.synchronizePendingAudio(
      upload:
          ({
            required String incidentId,
            required List<int> bytes,
            required String fileName,
            required String mimeType,
          }) async {
            expect(incidentId, 'server-audio-001');
            expect(bytes, <int>[1, 2, 3, 4]);
            return {
              'success': true,
              'data': {
                'audio_received': true,
                'evidence_hash_calculated': true,
              },
            };
          },
    );

    incident = (await database.getAllIncidents()).single;
    expect(incident['audio_ack_status'], 'received');
    expect(incident['evidence_hash_status'], 'calculated');
    expect(incident['sync_state'], 'SERVER_CONFIRMED');

    await database.markNotificationSubmitted(clientEventId: eventId);
    incident = (await database.getAllIncidents()).single;
    expect(incident['sync_state'], 'SYNCHRONIZED');
    expect(incident['full_sync_status'], 'completed');

    service.dispose();
  });

  test('already-synchronized incident is not uploaded again', () async {
    await saveIncident();

    var httpCalls = 0;

    final mockClient = MockClient((request) async {
      httpCalls++;

      if (request.url.path == '/api/devices/register/') {
        return http.Response(jsonEncode({'id': 'device-004'}), 201);
      }

      return http.Response(
        jsonEncode({'id': 'server-004'}),
        201,
        headers: {'content-type': 'application/json'},
      );
    });

    final service = IncidentSyncService(
      database: database,
      client: mockClient,
      connectivityChecker: () async => [ConnectivityResult.wifi],
    );

    final firstResult = await service.synchronizePendingIncidents(
      token: 'test-token',
    );

    expect(firstResult, isTrue);
    expect(httpCalls, 2);

    final secondResult = await service.synchronizePendingIncidents(
      token: 'test-token',
    );

    expect(secondResult, isTrue);

    // The second call should find no pending incidents.
    expect(httpCalls, 2);

    final incidents = await database.getAllIncidents();

    expect(incidents, hasLength(1));
    expect(incidents.single['sync_status'], 'synced');
    expect(incidents.single['server_incident_id'], 'server-004');

    service.dispose();
  });

  test(
    'malformed server acknowledgment does not mark incident synced',
    () async {
      await saveIncident();

      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/devices/register/') {
          return http.Response(jsonEncode({'id': 'device-005'}), 201);
        }

        return http.Response(
          jsonEncode({'detail': 'Accepted without an ID'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = IncidentSyncService(
        database: database,
        client: mockClient,
        connectivityChecker: () async => [ConnectivityResult.wifi],
      );

      final result = await service.synchronizePendingIncidents(
        token: 'test-token',
      );

      expect(result, isFalse);

      final incidents = await database.getAllIncidents();

      expect(incidents, hasLength(1));
      expect(incidents.single['sync_status'], 'failed');
      expect(incidents.single['server_incident_id'], isNull);

      service.dispose();
    },
  );
}

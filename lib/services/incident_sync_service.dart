import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'local_database_service.dart';

typedef ConnectivityChecker = Future<List<ConnectivityResult>> Function();

class IncidentSyncService {
  final LocalDatabaseService database;
  final http.Client client;
  final ConnectivityChecker connectivityChecker;

  IncidentSyncService({
    LocalDatabaseService? database,
    http.Client? client,
    ConnectivityChecker? connectivityChecker,
  })  : database = database ?? LocalDatabaseService.instance,
        client = client ?? http.Client(),
        connectivityChecker = connectivityChecker ??
            (() => Connectivity().checkConnectivity());

  Future<void> synchronizePendingAudio({
    required Future<Map<String, dynamic>> Function({
      required String incidentId,
      required List<int> bytes,
      required String fileName,
      required String mimeType,
    }) upload,
  }) async {
    final pendingAudio = await database.getPendingIncidentAudio();

    for (final audio in pendingAudio) {
      final clientEventId = audio['client_event_id'] as String;
      final serverIncidentId = audio['server_incident_id'] as String;
      final result = await upload(
        incidentId: serverIncidentId,
        bytes: List<int>.from(audio['bytes'] as List),
        fileName: audio['file_name'] as String,
        mimeType: audio['mime_type'] as String,
      );

      if (result['success'] == true) {
        await database.markAudioUploaded(clientEventId: clientEventId);
      } else {
        await database.markAudioUploadFailed(
          clientEventId: clientEventId,
          error: result['message']?.toString() ?? 'Audio upload failed.',
        );
      }
    }
  }

  Future<bool> synchronizePendingIncidents({
    required String token,
  }) async {
    // A network interface may exist without internet access.
    // HTTP failures are handled separately below.
    final connectivity = await connectivityChecker();

    if (connectivity.contains(ConnectivityResult.none)) {
      return false;
    }

    final pending = await database.getPendingIncidents();

    var allSucceeded = true;

    for (final incident in pending) {
      final eventId = incident['client_event_id'] as String;

      try {
        final latitude = incident['latitude'] as num?;
        final longitude = incident['longitude'] as num?;

        final payload = <String, dynamic>{
          'client_event_id': eventId,
          'wearable_event_id': eventId,
          'device_identifier': incident['device_identifier'],
          'event_type': incident['event_type'],
          'source': 'wearable',
          'is_sos': true,
          'threat_level': incident['threat_level'] ?? 'medium',
          'description': incident['description'] ?? '',
          'occurred_at': incident['captured_at'],
          'location_captured_at': incident['location_captured_at'],
          'latitude': latitude,
          'longitude': longitude,
          'location_accuracy_m': incident['location_accuracy'],
          'location_source': incident['location_source'],
        };

        payload.removeWhere((key, value) => value == null);

        final response = await client
            .post(
              Uri.parse(
                '${ApiConfig.baseUrl}${ApiConfig.incidentsEndpoint}',
              ),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Token $token',
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode == 200 ||
            response.statusCode == 201) {
          final decoded = jsonDecode(response.body);

          if (decoded is! Map<String, dynamic> ||
              decoded['id'] == null) {
            throw const FormatException(
              'Server response is missing the incident ID.',
            );
          }

          final serverIncidentId = decoded['id'].toString();

          final updatedRows = await database.markIncidentSynced(
            clientEventId: eventId,
            serverIncidentId: serverIncidentId,
          );

          if (updatedRows != 1) {
            throw StateError(
              'The local incident acknowledgment could not be saved.',
            );
          }

          await database.attachAudioToServerIncident(
            clientEventId: eventId,
            serverIncidentId: serverIncidentId,
          );
        } else {
          allSucceeded = false;

          await database.markIncidentFailed(
            clientEventId: eventId,
            error: 'HTTP ${response.statusCode}',
          );
        }
      } catch (error) {
        allSucceeded = false;

        await database.markIncidentFailed(
          clientEventId: eventId,
          error: error.toString(),
        );
      }
    }

    return allSucceeded;
  }

  void dispose() {
    client.close();
  }
}

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
  bool _syncInProgress = false;

  IncidentSyncService({
    LocalDatabaseService? database,
    http.Client? client,
    ConnectivityChecker? connectivityChecker,
  }) : database = database ?? LocalDatabaseService.instance,
       client = client ?? http.Client(),
       connectivityChecker =
           connectivityChecker ?? (() => Connectivity().checkConnectivity());

  Future<void> synchronizePendingAudio({
    required Future<Map<String, dynamic>> Function({
      required String incidentId,
      required List<int> bytes,
      required String fileName,
      required String mimeType,
    })
    upload,
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
        final data = result['data'];
        final acknowledgements = data is Map<String, dynamic>
            ? data
            : <String, dynamic>{};
        final evidenceHash = acknowledgements['sha256_hash']?.toString();
        final hashCalculated =
            evidenceHash != null && evidenceHash.trim().isNotEmpty;
        await database.updateIncidentAcknowledgements(
          clientEventId: clientEventId,
          audioReceived: _ackBool(acknowledgements, const [
            'audio_received',
            'audio_file_received',
          ], fallback: true),
          hashCalculated: _ackBool(acknowledgements, const [
            'evidence_hash_calculated',
            'hash_calculated',
          ], fallback: hashCalculated),
        );
        if (hashCalculated) {
          await database.markEvidenceHashCalculated(
            clientEventId: clientEventId,
            hash: evidenceHash,
          );
        }
      } else {
        await database.markAudioUploadFailed(
          clientEventId: clientEventId,
          error: result['message']?.toString() ?? 'Audio upload failed.',
        );
      }
    }
  }

  Future<bool> synchronizePendingIncidents({required String token}) async {
    if (_syncInProgress) return false;
    _syncInProgress = true;
    try {
      return await _synchronizePendingIncidents(token: token);
    } finally {
      _syncInProgress = false;
    }
  }

  Future<bool> _synchronizePendingIncidents({required String token}) async {
    // A network interface may exist without internet access.
    // HTTP failures are handled separately below.
    final connectivity = await connectivityChecker();

    if (connectivity.contains(ConnectivityResult.none)) {
      for (final incident in await database.getPendingIncidents()) {
        await database.markIncidentWaitingForNetwork(
          clientEventId: incident['client_event_id'] as String,
        );
      }
      return false;
    }

    final pending = await database.getPendingIncidents();

    var allSucceeded = true;

    for (final incident in pending) {
      final eventId = incident['client_event_id'] as String;

      try {
        await database.markIncidentUploading(clientEventId: eventId);
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
              Uri.parse('${ApiConfig.baseUrl}${ApiConfig.incidentsEndpoint}'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Token $token',
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          dynamic decoded;
          try {
            decoded = jsonDecode(response.body);
          } catch (_) {
            decoded = null;
          }

          if (decoded is! Map<String, dynamic> ||
              (decoded['id'] ??
                      decoded['incident_id'] ??
                      decoded['server_incident_id']) ==
                  null) {
            throw const FormatException(
              'Server response is missing the incident ID.',
            );
          }

          final serverIncidentId =
              (decoded['id'] ??
                      decoded['incident_id'] ??
                      decoded['server_incident_id'])
                  .toString();
          final acknowledgements = _acknowledgements(decoded);

          final updatedRows = await database.markIncidentServerConfirmed(
            clientEventId: eventId,
            serverIncidentId: serverIncidentId,
            acknowledgements: acknowledgements,
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
          await database.markIncidentSynchronized(clientEventId: eventId);
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

  Map<String, dynamic> _acknowledgements(Map<String, dynamic> decoded) {
    final nested = decoded['acknowledgements'];
    if (nested is Map<String, dynamic>) {
      return {...decoded, ...nested};
    }
    return decoded;
  }

  bool _ackBool(
    Map<String, dynamic> acknowledgements,
    List<String> keys, {
    bool fallback = false,
  }) {
    for (final key in keys) {
      final value = acknowledgements[key];
      if (value is bool) return value;
      if (value is Map && value['received'] is bool) {
        return value['received'] as bool;
      }
      if (value is Map && value['status'] != null) {
        return const {
          'received',
          'calculated',
          'submitted',
          'complete',
          'completed',
        }.contains(value['status'].toString().toLowerCase());
      }
    }
    return fallback;
  }

  void dispose() {
    client.close();
  }
}

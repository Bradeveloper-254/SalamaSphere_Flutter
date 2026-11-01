import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class LocalDatabaseService {
  static final LocalDatabaseService instance = LocalDatabaseService._internal();

  LocalDatabaseService._internal() : _testDatabasePath = null;

  // Allows tests to use a separate SQLite database file.
  LocalDatabaseService.forTesting(this._testDatabasePath);

  final String? _testDatabasePath;

  Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initializeDatabase();
    return _database!;
  }

  Future<Database> _initializeDatabase() async {
    final String path;

    if (_testDatabasePath != null) {
      path = _testDatabasePath;
    } else {
      final databasePath = await getDatabasesPath();
      path = p.join(databasePath, 'salamasphere.db');
    }

    return openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE incidents (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_event_id TEXT NOT NULL UNIQUE,
            device_identifier TEXT NOT NULL,
            event_type TEXT NOT NULL,
            threat_level TEXT NOT NULL DEFAULT 'medium',
            description TEXT,
            captured_at TEXT NOT NULL,
            latitude REAL,
            longitude REAL,
            location_accuracy REAL,
            location_captured_at TEXT,
            location_source TEXT,
            sync_status TEXT NOT NULL DEFAULT 'pending',
            sync_state TEXT NOT NULL DEFAULT 'SAVED_LOCALLY',
            server_incident_id TEXT,
            metadata_ack_status TEXT NOT NULL DEFAULT 'pending',
            audio_ack_status TEXT NOT NULL DEFAULT 'pending',
            evidence_hash_status TEXT NOT NULL DEFAULT 'pending',
            notification_ack_status TEXT NOT NULL DEFAULT 'pending',
            full_sync_status TEXT NOT NULL DEFAULT 'pending',
            server_status TEXT,
            server_acknowledged_at TEXT,
            retry_count INTEGER NOT NULL DEFAULT 0,
            last_sync_error TEXT,
            created_at TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE INDEX idx_incidents_sync_status
          ON incidents(sync_status)
        ''');

        await db.execute('''
          CREATE INDEX idx_incidents_captured_at
          ON incidents(captured_at)
        ''');

        await db.execute('''
          CREATE TABLE incident_audio (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            client_event_id TEXT NOT NULL UNIQUE,
            bytes BLOB NOT NULL,
            file_name TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            upload_status TEXT NOT NULL DEFAULT 'pending',
            server_incident_id TEXT,
            protected_upload_status TEXT NOT NULL DEFAULT 'pending',
            evidence_hash TEXT,
            evidence_hash_status TEXT NOT NULL DEFAULT 'pending',
            last_upload_error TEXT,
            created_at TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE incidents ADD COLUMN threat_level TEXT NOT NULL DEFAULT 'medium'",
          );

          await db.execute('ALTER TABLE incidents ADD COLUMN description TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE incident_audio (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              client_event_id TEXT NOT NULL UNIQUE,
              bytes BLOB NOT NULL,
              file_name TEXT NOT NULL,
              mime_type TEXT NOT NULL,
              upload_status TEXT NOT NULL DEFAULT 'pending',
              server_incident_id TEXT,
              last_upload_error TEXT,
              created_at TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 4) {
          await db.execute(
            "ALTER TABLE incident_audio ADD COLUMN protected_upload_status TEXT NOT NULL DEFAULT 'pending'",
          );
        }
        if (oldVersion < 5) {
          await db.execute(
            "ALTER TABLE incidents ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'SAVED_LOCALLY'",
          );
          await db.execute(
            "ALTER TABLE incidents ADD COLUMN metadata_ack_status TEXT NOT NULL DEFAULT 'pending'",
          );
          await db.execute(
            "ALTER TABLE incidents ADD COLUMN audio_ack_status TEXT NOT NULL DEFAULT 'pending'",
          );
          await db.execute(
            "ALTER TABLE incidents ADD COLUMN evidence_hash_status TEXT NOT NULL DEFAULT 'pending'",
          );
          await db.execute(
            "ALTER TABLE incidents ADD COLUMN notification_ack_status TEXT NOT NULL DEFAULT 'pending'",
          );
          await db.execute(
            "ALTER TABLE incidents ADD COLUMN full_sync_status TEXT NOT NULL DEFAULT 'pending'",
          );
          await db.execute(
            'ALTER TABLE incidents ADD COLUMN server_status TEXT',
          );
          await db.execute(
            'ALTER TABLE incidents ADD COLUMN server_acknowledged_at TEXT',
          );
          await db.execute(
            "ALTER TABLE incident_audio ADD COLUMN evidence_hash TEXT",
          );
          await db.execute(
            "ALTER TABLE incident_audio ADD COLUMN evidence_hash_status TEXT NOT NULL DEFAULT 'pending'",
          );
        }
      },
    );
  }

  Future<int> saveIncident({
    required String clientEventId,
    required String deviceIdentifier,
    required String eventType,
    required DateTime capturedAt,
    String threatLevel = 'medium',
    String? description,
    double? latitude,
    double? longitude,
    double? locationAccuracy,
    DateTime? locationCapturedAt,
    String? locationSource,
  }) async {
    if (!{'low', 'medium', 'high'}.contains(threatLevel)) {
      throw ArgumentError('Invalid threat level.');
    }

    if ((latitude == null) != (longitude == null)) {
      throw ArgumentError(
        'Latitude and longitude must both be provided or both be null.',
      );
    }

    final db = await database;

    return db.insert('incidents', {
      'client_event_id': clientEventId,
      'device_identifier': deviceIdentifier,
      'event_type': eventType,
      'threat_level': threatLevel,
      'description': description,
      'captured_at': capturedAt.toUtc().toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'location_accuracy': locationAccuracy,
      'location_captured_at': locationCapturedAt?.toUtc().toIso8601String(),
      'location_source': locationSource,
      'sync_status': 'pending',
      'sync_state': 'SAVED_LOCALLY',
      'metadata_ack_status': 'pending',
      'audio_ack_status': 'pending',
      'evidence_hash_status': 'pending',
      'notification_ack_status': 'pending',
      'full_sync_status': 'pending',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, Object?>>> getAllIncidents() async {
    final db = await database;

    return db.query('incidents', orderBy: 'captured_at DESC');
  }

  Future<List<Map<String, Object?>>> getPendingIncidents() async {
    final db = await database;

    return db.query(
      'incidents',
      where: "sync_state IN (?, ?, ?) OR sync_status IN (?, ?)",
      whereArgs: [
        'SAVED_LOCALLY',
        'WAITING_FOR_NETWORK',
        'UPLOADING',
        'pending',
        'failed',
      ],
      orderBy: 'captured_at ASC',
    );
  }

  Future<int> markIncidentSynced({
    required String clientEventId,
    required String serverIncidentId,
  }) async {
    return markIncidentServerConfirmed(
      clientEventId: clientEventId,
      serverIncidentId: serverIncidentId,
      acknowledgements: const {},
    );
  }

  Future<int> markIncidentWaitingForNetwork({
    required String clientEventId,
  }) async {
    final db = await database;
    return db.update(
      'incidents',
      {'sync_state': 'WAITING_FOR_NETWORK'},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<int> markIncidentUploading({required String clientEventId}) async {
    final db = await database;
    return db.update(
      'incidents',
      {'sync_state': 'UPLOADING'},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<int> markIncidentServerConfirmed({
    required String clientEventId,
    required String serverIncidentId,
    required Map<String, dynamic> acknowledgements,
  }) async {
    final db = await database;
    final metadataReceived = _ackBool(acknowledgements, const [
      'metadata_received',
      'incident_received',
      'metadata',
    ], fallback: true);
    final audioRows = await db.query(
      'incident_audio',
      columns: ['client_event_id'],
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
      limit: 1,
    );
    final hasAudio = audioRows.isNotEmpty;
    final audioReceived = _ackBool(acknowledgements, const [
      'audio_received',
      'audio_file_received',
    ], fallback: !hasAudio);
    final hashCalculated = _ackBool(acknowledgements, const [
      'evidence_hash_calculated',
      'hash_calculated',
    ], fallback: !hasAudio);
    final notificationSubmitted = _ackBool(acknowledgements, const [
      'notification_submitted',
    ]);
    return db.update(
      'incidents',
      {
        'sync_status': 'synced',
        'sync_state': 'SERVER_CONFIRMED',
        'server_incident_id': serverIncidentId,
        'metadata_ack_status': metadataReceived ? 'received' : 'pending',
        'audio_ack_status': audioReceived ? 'received' : 'pending',
        'evidence_hash_status': hashCalculated
            ? 'calculated'
            : hasAudio
            ? 'pending'
            : 'not_applicable',
        'notification_ack_status': notificationSubmitted
            ? 'submitted'
            : 'pending',
        'server_status': acknowledgements['status']?.toString(),
        'server_acknowledged_at': DateTime.now().toUtc().toIso8601String(),
        'last_sync_error': null,
      },
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<int> updateIncidentAcknowledgements({
    required String clientEventId,
    bool? audioReceived,
    bool? hashCalculated,
    bool? notificationSubmitted,
  }) async {
    final db = await database;
    final values = <String, Object?>{
      if (audioReceived != null)
        'audio_ack_status': audioReceived ? 'received' : 'pending',
      if (hashCalculated != null)
        'evidence_hash_status': hashCalculated ? 'calculated' : 'pending',
      if (notificationSubmitted != null)
        'notification_ack_status': notificationSubmitted
            ? 'submitted'
            : 'pending',
    };
    if (values.isEmpty) return 0;
    final updated = await db.update(
      'incidents',
      values,
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
    await markIncidentSynchronized(clientEventId: clientEventId);
    return updated;
  }

  Future<int> markIncidentSynchronized({required String clientEventId}) async {
    final db = await database;
    final rows = await db.query(
      'incidents',
      columns: [
        'metadata_ack_status',
        'audio_ack_status',
        'evidence_hash_status',
        'notification_ack_status',
      ],
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    final row = rows.first;
    final complete = row.values.every(
      (value) => const {
        'received',
        'calculated',
        'submitted',
        'not_applicable',
      }.contains(value),
    );
    if (!complete) return 0;
    return db.update(
      'incidents',
      {'sync_state': 'SYNCHRONIZED', 'full_sync_status': 'completed'},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
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

  Future<int> markIncidentFailed({
    required String clientEventId,
    required String error,
  }) async {
    final db = await database;

    return db.rawUpdate(
      '''
      UPDATE incidents
      SET sync_status = 'failed',
          sync_state = 'WAITING_FOR_NETWORK',
          retry_count = retry_count + 1,
          last_sync_error = ?
      WHERE client_event_id = ?
      ''',
      [error, clientEventId],
    );
  }

  Future<int> updateIncidentLocation({
    required String clientEventId,
    required double latitude,
    required double longitude,
    required double accuracy,
    required DateTime capturedAt,
    required String source,
  }) async {
    final db = await database;

    return db.update(
      'incidents',
      {
        'latitude': latitude,
        'longitude': longitude,
        'location_accuracy': accuracy,
        'location_captured_at': capturedAt.toUtc().toIso8601String(),
        'location_source': source,
      },
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<Map<String, Object?>?> getIncident(String clientEventId) async {
    final db = await database;
    final rows = await db.query(
      'incidents',
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> saveIncidentAudio({
    required String clientEventId,
    required List<int> bytes,
    String fileName = 'sos-audio.wav',
    String mimeType = 'audio/wav',
  }) async {
    final db = await database;

    return db.insert('incident_audio', {
      'client_event_id': clientEventId,
      'bytes': Uint8List.fromList(bytes),
      'file_name': fileName,
      'mime_type': mimeType,
      'upload_status': 'pending',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> getIncidentAudio(String clientEventId) async {
    final db = await database;
    final rows = await db.query(
      'incident_audio',
      columns: [
        'client_event_id',
        'file_name',
        'mime_type',
        'upload_status',
        'protected_upload_status',
        'server_incident_id',
        'created_at',
      ],
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<int>?> getIncidentAudioBytes(String clientEventId) async {
    final db = await database;
    final rows = await db.query(
      'incident_audio',
      columns: ['bytes'],
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['bytes'] == null) return null;
    return List<int>.from(rows.first['bytes'] as List);
  }

  Future<List<Map<String, Object?>>> getPendingIncidentAudio() async {
    final db = await database;
    return db.query(
      'incident_audio',
      where: "upload_status IN ('pending', 'failed') AND server_incident_id IS NOT NULL",
      orderBy: 'created_at ASC',
    );
  }

  Future<int> markAudioUploaded({required String clientEventId}) async {
    final db = await database;
    return db.update(
      'incident_audio',
      {'upload_status': 'uploaded', 'last_upload_error': null},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<int> markAudioUploadFailed({
    required String clientEventId,
    required String error,
  }) async {
    final db = await database;
    return db.update(
      'incident_audio',
      {'upload_status': 'failed', 'last_upload_error': error},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<int> markEvidenceHashCalculated({
    required String clientEventId,
    String? hash,
  }) async {
    final db = await database;
    final updated = await db.update(
      'incident_audio',
      {'evidence_hash': hash, 'evidence_hash_status': 'calculated'},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
    await updateIncidentAcknowledgements(
      clientEventId: clientEventId,
      hashCalculated: true,
    );
    return updated;
  }

  Future<int> markProtectedMediaUploaded({
    required String clientEventId,
  }) async {
    final db = await database;
    return db.update(
      'incident_audio',
      {'protected_upload_status': 'uploaded'},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<int> markNotificationSubmitted({required String clientEventId}) {
    return updateIncidentAcknowledgements(
      clientEventId: clientEventId,
      notificationSubmitted: true,
    );
  }

  Future<int> attachAudioToServerIncident({
    required String clientEventId,
    required String serverIncidentId,
  }) async {
    final db = await database;
    return db.update(
      'incident_audio',
      {'server_incident_id': serverIncidentId},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
  }

  Future<void> close() async {
    final db = _database;

    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}

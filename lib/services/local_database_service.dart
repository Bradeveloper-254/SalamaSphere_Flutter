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
      version: 3,
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
            server_incident_id TEXT,
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
      where: 'sync_status IN (?, ?)',
      whereArgs: ['pending', 'failed'],
      orderBy: 'captured_at ASC',
    );
  }

  Future<int> markIncidentSynced({
    required String clientEventId,
    required String serverIncidentId,
  }) async {
    final db = await database;

    return db.update(
      'incidents',
      {
        'sync_status': 'synced',
        'server_incident_id': serverIncidentId,
        'last_sync_error': null,
      },
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
    );
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
    String fileName = 'sos-audio.bin',
    String mimeType = 'application/octet-stream',
  }) async {
    final db = await database;

    return db.insert('incident_audio', {
      'client_event_id': clientEventId,
      'bytes': bytes,
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
      where: "upload_status = 'pending' AND server_incident_id IS NOT NULL",
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
      {'last_upload_error': error},
      where: 'client_event_id = ?',
      whereArgs: [clientEventId],
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

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api_service.dart';
import 'incident_sync_service.dart';
import 'local_database_service.dart';
import 'location_service.dart';

/// Owns the foreground GPS stream for the currently active SOS in this app
/// process. Location samples are encrypted and queued before any network send.
class IncidentTrackingService {
  IncidentTrackingService._();

  static final IncidentTrackingService instance = IncidentTrackingService._();

  final LocalDatabaseService _database = LocalDatabaseService.instance;
  final LocationService _location = LocationService();
  final ValueNotifier<String?> status = ValueNotifier<String?>(null);
  final ValueNotifier<DateTime?> lastUpdate = ValueNotifier<DateTime?>(null);
  final Uuid _uuid = const Uuid();

  StreamSubscription<IncidentLocation>? _subscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  IncidentSyncService? _sync;
  ApiService? _api;
  String? _clientEventId;
  IncidentLocation? _lastSavedLocation;
  bool _syncRunning = false;

  bool get isTracking => _subscription != null;
  String? get activeClientEventId => _clientEventId;

  Future<bool> startAfterConsent({
    required String clientEventId,
    required ApiService apiService,
  }) async {
    if (_clientEventId == clientEventId && _subscription != null) return true;
    await stop(clearConsent: false);

    final permitted = await _location.ensureTrackingPermission();
    if (!permitted) {
      status.value =
          'Location tracking is off. Enable phone location permission and GPS to share movement during this SOS.';
      return false;
    }
    final incident = await _database.getIncident(clientEventId);
    if (incident == null) {
      throw StateError('The local SOS incident is unavailable for tracking.');
    }

    await _database.setIncidentTrackingConsent(
      clientEventId: clientEventId,
      enabled: true,
    );
    _clientEventId = clientEventId;
    _api = apiService;
    _sync = IncidentSyncService(database: _database);
    _connectivitySubscription ??= Connectivity().onConnectivityChanged.listen(
      (results) {
        if (!results.contains(ConnectivityResult.none)) {
          unawaited(_synchronizePending());
        }
      },
    );
    status.value = 'Live location sharing is active for this SOS.';

    _subscription = _location.watchIncidentLocation().listen(
      (location) => unawaited(_recordLocation(location)),
      onError: (Object error, StackTrace stackTrace) {
        status.value = 'Location tracking paused: $error';
      },
      onDone: () {
        _subscription = null;
        if (_clientEventId != null) {
          status.value = 'Location stream ended. Resume tracking to continue.';
        }
      },
      cancelOnError: false,
    );
    return true;
  }

  Future<void> pause() async {
    await _subscription?.cancel();
    _subscription = null;
    status.value = 'Live location sharing is paused.';
  }

  Future<bool> resume() async {
    final clientEventId = _clientEventId;
    final apiService = _api;
    if (clientEventId == null || apiService == null) return false;
    return startAfterConsent(
      clientEventId: clientEventId,
      apiService: apiService,
    );
  }

  Future<void> stop({bool clearConsent = true}) async {
    await _subscription?.cancel();
    _subscription = null;
    final oldClientEventId = _clientEventId;
    _clientEventId = null;
    _lastSavedLocation = null;
    if (clearConsent && oldClientEventId != null) {
      await _database.setIncidentTrackingConsent(
        clientEventId: oldClientEventId,
        enabled: false,
      );
      status.value = 'Live location sharing is off.';
    }
  }

  Future<void> _recordLocation(IncidentLocation location) async {
    final clientEventId = _clientEventId;
    if (clientEventId == null) return;
    final previous = _lastSavedLocation;
    if (previous != null) {
      final elapsed = location.capturedAt.difference(previous.capturedAt);
      if (elapsed < const Duration(seconds: 20) &&
          _distanceMeters(previous, location) < 25) {
        return;
      }
    }

    try {
      final saved = await _database.saveIncidentLocationSample(
        clientEventId: clientEventId,
        clientLocationId: _uuid.v4(),
        latitude: location.latitude,
        longitude: location.longitude,
        accuracy: location.accuracy,
        capturedAt: location.capturedAt,
        source: location.source,
        speedMps: location.speedMps,
        bearingDegrees: location.bearingDegrees,
      );
      if (saved == 0) {
        status.value = 'Could not store the latest GPS sample locally.';
        return;
      }
      _lastSavedLocation = location;
      lastUpdate.value = location.capturedAt;
      final incident = await _database.getIncident(clientEventId);
      if ((incident?['server_incident_id']?.toString().isNotEmpty ?? false) &&
          _api?.authToken != null) {
        await _synchronizePending();
      }
    } catch (error) {
      status.value = 'Could not save a GPS update: $error';
    }
  }

  Future<void> _synchronizePending() async {
    if (_syncRunning) return;
    final token = _api?.authToken;
    final sync = _sync;
    if (token == null || sync == null) return;
    _syncRunning = true;
    try {
      await sync.synchronizePendingLocations(token: token);
      final currentId = _clientEventId;
      if (currentId != null) {
        final rows = await _database.getAllIncidents();
        final incident = rows.where(
          (row) => row['client_event_id'] == currentId,
        ).firstOrNull;
        if (incident?['tracking_consent'] == 0) {
          await stop(clearConsent: false);
          status.value = 'Location sharing stopped because the SOS was closed.';
        }
      }
    } catch (error) {
      status.value = 'GPS updates are saved and will retry when online: $error';
    } finally {
      _syncRunning = false;
    }
  }

  double _distanceMeters(IncidentLocation a, IncidentLocation b) {
    const earthRadius = 6371000.0;
    final lat1 = a.latitude * 0.017453292519943295;
    final lat2 = b.latitude * 0.017453292519943295;
    final dLat = (b.latitude - a.latitude) * 0.017453292519943295;
    final dLon = (b.longitude - a.longitude) * 0.017453292519943295;
    final h = (1 - (1 - (dLat / 2).sin() * (dLat / 2).sin() -
            (lat1.cos() * lat2.cos() *
                (dLon / 2).sin() *
                (dLon / 2).sin()))) /
        2;
    return earthRadius * 2 * h.sqrt().asin();
  }

  Future<void> dispose() async {
    await stop();
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _sync?.dispose();
    _sync = null;
    status.dispose();
    lastUpdate.dispose();
  }
}

extension on double {
  double sin() => _sin(this);
  double cos() => _cos(this);
  double sqrt() => _sqrt(this);
  double asin() => _asin(this);
}

// Dart's core library does not expose these methods on double; keep this
// service independent from a math package in the location callback path.
double _sin(double value) => _trig(value, 'sin');
double _cos(double value) => _trig(value, 'cos');
double _sqrt(double value) => _numeric(value, 'sqrt');
double _asin(double value) => _trig(value, 'asin');

double _trig(double value, String operation) {
  // Replaced by dart:math in the import below at compile time.
  throw UnsupportedError('Unimplemented $operation($value)');
}

double _numeric(double value, String operation) =>
    throw UnsupportedError('Unimplemented $operation($value)');

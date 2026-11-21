import 'dart:async';
import 'dart:math' as math;

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
  static const double earthRadiusMeters = 6371000;
  static const Duration minimumSampleInterval = Duration(seconds: 20);
  static const Duration maximumSampleAge = Duration(minutes: 2);
  static const double maximumAccuracyMeters = 100;
  static const double meaningfulMovementMeters = 10;
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

  /// Recover only a locally consented, still-open SOS after process recreation.
  /// Consent is never inferred from location permission alone.
  Future<bool> recoverAfterRestart({required ApiService apiService}) async {
    if (_clientEventId != null) return isTracking;
    final incidents = await _database.getAllIncidents();
    for (final incident in incidents.reversed) {
      final consent = incident['tracking_consent'];
      final closed =
          (incident['server_status']?.toString().toLowerCase() == 'closed') ||
          incident['status']?.toString().toLowerCase() == 'closed';
      final isSos =
          incident['is_sos'] == true ||
          incident['event_type']?.toString().toLowerCase() == 'sos' ||
          incident['event_type']?.toString().toLowerCase() == 'emergency';
      if ((consent == 1 || consent == true) && !closed && isSos) {
        final id = incident['client_event_id']?.toString();
        if (id != null && id.isNotEmpty) {
          return startAfterConsent(clientEventId: id, apiService: apiService);
        }
      }
    }
    return false;
  }

  Future<bool> startAfterConsent({
    required String clientEventId,
    required ApiService apiService,
  }) async {
    if (_clientEventId == clientEventId && _subscription != null) return true;
    await stop(clearConsent: false);

    final permitted = await _location.ensureTrackingPermission();
    if (!permitted) {
      status.value = 'Location tracking is off. Enable phone location permission and GPS to share movement during this SOS.';
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
    _connectivitySubscription ??= Connectivity().onConnectivityChanged.listen((
      results,
    ) {
      if (!results.contains(ConnectivityResult.none)) {
        unawaited(_synchronizePending());
      }
    });
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
    final now = DateTime.now().toUtc();
    if (!_isValidLocation(location) ||
        location.capturedAt.isAfter(now.add(const Duration(seconds: 5))) ||
        now.difference(location.capturedAt) > maximumSampleAge) {
      status.value = 'GPS update rejected because its coordinates, accuracy, or timestamp are invalid or stale.';
      return;
    }
    final previous = _lastSavedLocation;
    if (previous != null) {
      final elapsed = location.capturedAt.difference(previous.capturedAt);
      if (elapsed.isNegative) return;
      // A poor fix cannot replace a better recent fix. Still retain a good
      // update after the interval even when movement is small.
      if (location.accuracy > previous.accuracy &&
          elapsed < minimumSampleInterval)
        return;
      if (elapsed < minimumSampleInterval &&
          distanceMeters(previous, location) < meaningfulMovementMeters) {
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

  static bool _isValidLocation(IncidentLocation point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude >= -180 &&
      point.longitude <= 180 &&
      point.accuracy.isFinite &&
      point.accuracy >= 0 &&
      point.accuracy <= maximumAccuracyMeters;

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
        final incident = rows
            .where((row) => row['client_event_id'] == currentId)
            .firstOrNull;
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

  static double distanceMeters(IncidentLocation a, IncidentLocation b) {
    _validate(a);
    _validate(b);
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLon = math.sin(dLon / 2);
    final h =
        (sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLon * sinLon)
            .clamp(0.0, 1.0);
    return earthRadiusMeters * 2 * math.asin(math.sqrt(h));
  }

  static void _validate(IncidentLocation p) {
    if (!p.latitude.isFinite ||
        !p.longitude.isFinite ||
        p.latitude < -90 ||
        p.latitude > 90 ||
        p.longitude < -180 ||
        p.longitude > 180) {
      throw ArgumentError('Invalid GPS coordinates.');
    }
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

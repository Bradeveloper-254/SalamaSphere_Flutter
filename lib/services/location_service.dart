import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

double normalizeCoordinateForApi(double value) =>
    double.parse(value.toStringAsFixed(6));

Uri? googleMapsUriForCoordinates(Object? latitude, Object? longitude) {
  final lat = double.tryParse(latitude?.toString() ?? '');
  final lon = double.tryParse(longitude?.toString() ?? '');
  if (lat == null ||
      lon == null ||
      !lat.isFinite ||
      !lon.isFinite ||
      lat < -90 ||
      lat > 90 ||
      lon < -180 ||
      lon > 180) {
    return null;
  }
  return Uri.https('www.google.com', '/maps/search/', {
    'api': '1',
    'query': '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}',
  });
}

class IncidentLocation {
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime capturedAt;
  final double? speedMps;
  final double? bearingDegrees;
  final String source;

  const IncidentLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.capturedAt,
    this.speedMps,
    this.bearingDegrees,
    this.source = 'phone_gps',
  });
}

class LocationService {
  static const _lastKnownMaxAge = Duration(minutes: 2);

  Future<IncidentLocation?> captureLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) return null;

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 30),
          ),
        );
        return _toIncidentLocation(position);
      } on TimeoutException {
        return await _freshLastKnownLocation();
      } catch (error) {
        debugPrint('Current incident location lookup failed: $error');
        return await _freshLastKnownLocation();
      }
    } catch (error) {
      debugPrint('Incident location permission or service failed: $error');
      return null;
    }
  }

  Future<bool> ensureTrackingPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission != LocationPermission.denied &&
        permission != LocationPermission.deniedForever;
  }

  Stream<IncidentLocation> watchIncidentLocation() async* {
    if (!await ensureTrackingPermission()) {
      throw StateError('Location permission or device location is unavailable.');
    }
    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 25,
            intervalDuration: const Duration(seconds: 30),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'SalamaSphere SOS location sharing',
              notificationText:
                  'Your location is being shared with authorized responders.',
              notificationChannelName: 'Active SOS location',
              enableWakeLock: true,
              setOngoing: true,
            ),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 25,
          );
    await for (final position in Geolocator.getPositionStream(
      locationSettings: settings,
    )) {
      yield _toIncidentLocation(position);
    }
  }

  Future<IncidentLocation?> _freshLastKnownLocation() async {
    try {
      final position = await Geolocator.getLastKnownPosition();
      if (position == null) return null;
      final age = DateTime.now().toUtc().difference(position.timestamp.toUtc());
      if (age.isNegative || age > _lastKnownMaxAge) return null;
      return _toIncidentLocation(position);
    } catch (error) {
      debugPrint('Last known incident location lookup failed: $error');
      return null;
    }
  }

  IncidentLocation _toIncidentLocation(Position position) {
    return IncidentLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy: position.accuracy,
      capturedAt: position.timestamp.toUtc(),
      speedMps: position.speed.isFinite && position.speed >= 0
          ? position.speed
          : null,
      bearingDegrees: position.heading.isFinite &&
              position.heading >= 0 &&
              position.heading < 360
          ? position.heading
          : null,
      source: 'phone_gps',
    );
  }
}

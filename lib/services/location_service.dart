import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class IncidentLocation {
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime capturedAt;

  const IncidentLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.capturedAt,
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
    );
  }
}

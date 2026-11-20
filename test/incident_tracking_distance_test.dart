import 'package:flutter_test/flutter_test.dart';
import 'package:salamasphere_mobile/services/incident_tracking_service.dart';
import 'package:salamasphere_mobile/services/location_service.dart';

IncidentLocation point(double lat, double lon) => IncidentLocation(
  latitude: lat,
  longitude: lon,
  accuracy: 1,
  capturedAt: DateTime.utc(2026),
);

void main() {
  test('Haversine handles identical, nearby and date line coordinates', () {
    expect(IncidentTrackingService.distanceMeters(point(0, 0), point(0, 0)), 0);
    expect(
      IncidentTrackingService.distanceMeters(point(0, 0), point(0, 0.001)),
      closeTo(111.2, 0.5),
    );
    expect(
      IncidentTrackingService.distanceMeters(point(0, 179.9), point(0, -179.9)),
      closeTo(22239, 30),
    );
  });

  test('Haversine remains finite for antipodes and rejects invalid values', () {
    expect(
      IncidentTrackingService.distanceMeters(point(0, 0), point(0, 180)),
      closeTo(20015086, 10),
    );
    expect(
      () => IncidentTrackingService.distanceMeters(point(91, 0), point(0, 0)),
      throwsArgumentError,
    );
    expect(
      () => IncidentTrackingService.distanceMeters(
        point(0, double.nan),
        point(0, 0),
      ),
      throwsArgumentError,
    );
  });
}

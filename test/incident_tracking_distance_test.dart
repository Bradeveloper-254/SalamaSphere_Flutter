import 'package:flutter_test/flutter_test.dart';
import 'package:salamasphere_mobile/services/incident_tracking_service.dart';
import 'package:salamasphere_mobile/services/location_service.dart';

IncidentLocation point(double latitude, double longitude) => IncidentLocation(
  latitude: latitude,
  longitude: longitude,
  accuracy: 5,
  capturedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  test('Haversine supports same point, short movement and date line', () {
    expect(IncidentTrackingService.distanceMeters(point(0, 0), point(0, 0)), 0);
    expect(
      IncidentTrackingService.distanceMeters(point(0, 0), point(0, .001)),
      closeTo(111.2, 1),
    );
    expect(
      IncidentTrackingService.distanceMeters(point(0, 179.9), point(0, -179.9)),
      closeTo(22239, 50),
    );
  });

  test('Haversine rejects invalid and handles antipodal coordinates', () {
    expect(
      IncidentTrackingService.distanceMeters(point(0, 0), point(0, 180)),
      closeTo(20015086, 20),
    );
    expect(
      () => IncidentTrackingService.distanceMeters(point(91, 0), point(0, 0)),
      throwsArgumentError,
    );
    expect(
      () => IncidentTrackingService.distanceMeters(
        point(double.nan, 0),
        point(0, 0),
      ),
      throwsArgumentError,
    );
  });
}

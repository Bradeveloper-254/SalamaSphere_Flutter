import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:salamasphere_mobile/services/api_service.dart';
import 'package:salamasphere_mobile/services/location_service.dart';

void main() {
  test('Google Maps link uses validated incident coordinates', () {
    expect(normalizeCoordinateForApi(-1.2864123456789), -1.286412);
    final uri = googleMapsUriForCoordinates('-1.286412', '36.817212');

    expect(uri?.host, 'www.google.com');
    expect(uri?.path, '/maps/search/');
    expect(uri?.queryParameters['api'], '1');
    expect(uri?.queryParameters['query'], '-1.286412,36.817212');
    expect(googleMapsUriForCoordinates(91, 36), isNull);
    expect(googleMapsUriForCoordinates(-1, double.nan), isNull);
  });

  test('user incident upload includes captured location', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/health/') {
        return http.Response(
          jsonEncode({'status': 'healthy', 'database': 'connected'}),
          200,
        );
      }

      if (request.url.path == '/api/accounts/login/') {
        return http.Response(
          jsonEncode({'token': 'test-token', 'username': 'survivor'}),
          200,
        );
      }

      if (request.url.path == '/api/incidents/') {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['latitude'], -1.286412);
        expect(payload['longitude'], 36.817212);
        expect(payload['location_accuracy_m'], 8.5);
        expect(payload['location_source'], 'mobile_gps');
        return http.Response(jsonEncode({'id': 'incident-123'}), 201);
      }

      return http.Response('Unexpected request: ${request.url.path}', 404);
    });
    final apiService = ApiService(client: client);

    final login = await apiService.login(
      username: 'survivor',
      password: 'test-password',
    );
    expect(login['success'], isTrue);

    final response = await apiService.createUserIncident(
      description: 'Test location report',
      shareWith: 'authorities',
      latitude: -1.2864123456789,
      longitude: 36.8172123456789,
      locationAccuracy: 8.5,
      locationSource: 'mobile_gps',
    );

    expect(response['success'], isTrue);
    expect((response['data'] as Map<String, dynamic>)['id'], 'incident-123');
  });
}

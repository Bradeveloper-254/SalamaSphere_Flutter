import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:salamasphere_mobile/services/api_service.dart';

void main() {
  test('uploads video evidence from a byte stream', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/health/') {
        return http.Response(
          jsonEncode({'status': 'healthy', 'database': 'connected'}),
          200,
        );
      }
      if (request.url.path == '/api/accounts/login/') {
        return http.Response(jsonEncode({'token': 'test-token'}), 200);
      }
      if (request.url.path == '/api/incidents/incident-123/evidence/') {
        final multipart = request;
        expect(
          multipart.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        final body = utf8.decode(multipart.bodyBytes);
        expect(body, contains('name="media_type"'));
        expect(body, contains('video'));
        expect(body, contains('filename="test-video.mp4"'));
        expect(body, contains('video-data'));
        return http.Response(jsonEncode({'id': 'evidence-123'}), 201);
      }
      return http.Response('Unexpected request: ${request.url.path}', 404);
    });
    final apiService = ApiService(client: client);

    final login = await apiService.login(
      username: 'survivor',
      password: 'test-password',
    );
    expect(login['success'], isTrue);

    final response = await apiService.uploadEvidenceVault(
      incidentId: 'incident-123',
      fileStream: Stream<List<int>>.value(utf8.encode('video-data')),
      fileLength: 10,
      fileName: 'test-video.mp4',
      mimeType: 'video/mp4',
      shareWith: 'authorities',
    );

    expect(response['success'], isTrue, reason: response.toString());
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:salamasphere_mobile/services/api_service.dart';
import 'package:salamasphere_mobile/widgets/incident_media.dart';

class _MediaApiService extends ApiService {
  _MediaApiService()
    : super(
        client: MockClient(
          (_) async =>
              http.Response('{"status":"healthy","database":"connected"}', 200),
        ),
      );

  @override
  Future<Map<String, dynamic>> fetchIncidentEvidence(String incidentId) async {
    return {
      'success': true,
      'data': {
        'results': [
          {
            'id': 'evidence-123',
            'original_filename': 'incident-video.mp4',
            'evidence_type': 'video',
          },
        ],
      },
    };
  }
}

void main() {
  testWidgets('incident media lists uploaded videos for playback', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IncidentEvidenceList(
            apiService: _MediaApiService(),
            incidentId: 'incident-123',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('incident-video.mp4'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
  });
}
//esms_live_2d13912b0ce64a5fab48b5a3c4b4dff2

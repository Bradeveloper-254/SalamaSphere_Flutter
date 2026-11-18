import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:salamasphere_mobile/services/api_service.dart';

void main() {
  test(
    'transcription, retrieval, and review use authenticated API routes',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/health/') {
          return http.Response(
            jsonEncode({'status': 'healthy', 'database': 'connected'}),
            200,
          );
        }
        if (request.url.path == '/api/accounts/login/') {
          return http.Response(jsonEncode({'token': 'test-token'}), 200);
        }
        if (request.url.path == '/api/evidence/evidence-123/transcribe/') {
          return http.Response(
            jsonEncode({
              'transcript_id': 7,
              'language': 'sw',
              'transcript': 'Habari rafiki.',
              'human_review_required': true,
            }),
            201,
          );
        }
        if (request.url.path == '/api/evidence/evidence-123/transcripts/') {
          return http.Response(
            jsonEncode([
              {
                'transcript_id': 7,
                'status': 'completed',
                'transcript': 'Habari rafiki.',
                'reviewed_transcript': null,
                'history': [],
              },
            ]),
            200,
          );
        }
        if (request.url.path == '/api/transcripts/7/review/') {
          return http.Response(
            jsonEncode({
              'transcript_id': 7,
              'transcript': 'Habari rafiki.',
              'reviewed_transcript': 'Habari rafiki!',
            }),
            200,
          );
        }
        return http.Response('Unexpected request', 404);
      });
      final api = ApiService(client: client);
      final login = await api.login(
        username: 'survivor',
        password: 'test-password',
      );
      expect(login['success'], isTrue);

      final transcription = await api.transcribeEvidence(
        'evidence-123',
        language: 'sw',
      );
      expect(transcription['success'], isTrue);
      expect(jsonDecode(requests[2].body), {'language': 'sw'});

      final history = await api.fetchEvidenceTranscripts('evidence-123');
      expect(history['success'], isTrue);
      expect((history['data'] as List).single['transcript_id'], 7);

      final correction = await api.reviewEvidenceTranscript(
        transcriptId: '7',
        correctedText: 'Habari rafiki!',
      );
      expect(correction['success'], isTrue);
      expect(jsonDecode(requests.last.body), {'transcript': 'Habari rafiki!'});
      for (final request in requests.skip(2)) {
        expect(request.headers['authorization'], 'Token test-token');
      }
    },
  );
}

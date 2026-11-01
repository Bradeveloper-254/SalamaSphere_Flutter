import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config/api_config.dart';
import 'api_service.dart';

/// Uploads a verified wearable recording to the protected collections.
/// The backend remains responsible for enforcing victim/admin/authority
/// permissions; the client never exposes an unprotected media URL.
class ProtectedMediaService {
  ProtectedMediaService(this.apiService, {http.Client? client})
    : _client = client ?? http.Client();

  final ApiService apiService;
  final http.Client _client;

  Future<Map<String, dynamic>> uploadRecording({
    required String incidentId,
    required List<int> bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final token = apiService.authToken;
    if (token == null) {
      return {
        'success': false,
        'message': 'Please log in before uploading media.',
      };
    }

    final results = <String, dynamic>{
      'success': true,
      'uploads': <String>[],
      'acknowledgements': <String, dynamic>{},
    };
    for (final destination in <String, String>{
      'evidence_vault': ApiConfig.baseUrl + ApiConfig.evidenceVaultEndpoint,
      'private_media': ApiConfig.baseUrl + ApiConfig.privateMediaEndpoint,
    }.entries) {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(destination.value),
      );
      request.headers.addAll({
        'Accept': 'application/json',
        'Authorization': 'Token $token',
      });
      request.fields['incident'] = incidentId;
      request.fields['incident_id'] = incidentId;
      request.fields['media_type'] = 'audio';
      request.fields['visibility'] = destination.key == 'private_media'
          ? 'private'
          : 'protected';
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
          contentType: MediaType.parse(mimeType),
        ),
      );

      try {
        final response = await _client
            .send(request)
            .timeout(const Duration(seconds: 30));
        final body = await http.Response.fromStream(response);
        dynamic decoded;
        try {
          decoded = jsonDecode(body.body);
        } catch (_) {
          decoded = null;
        }
        final ok = response.statusCode >= 200 && response.statusCode < 300;
        if (ok) {
          (results['uploads'] as List<String>).add(destination.key);
          if (decoded is Map<String, dynamic>) {
            (results['acknowledgements'] as Map<String, dynamic>).addAll(
              decoded,
            );
          }
        } else {
          results['success'] = false;
          results['message'] = decoded is Map
              ? (decoded['detail'] ??
                    decoded['message'] ??
                    'Protected media upload failed.')
              : 'Protected media upload failed for ${destination.key}.';
        }
      } catch (error) {
        results['success'] = false;
        results['message'] = 'Could not upload ${destination.key}: $error';
      }
    }
    if ((results['uploads'] as List).isNotEmpty) {
      results['message'] = 'Recording uploaded to protected media.';
    }
    return results;
  }

  void dispose() => _client.close();
}

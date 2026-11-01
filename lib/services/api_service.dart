import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http_parser/http_parser.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../models/authority_verification_document.dart';
import '../config/api_config.dart';

String generateClientEventId() {
  final random = Random.secure();

  final bytes = List<int>.generate(16, (_) => random.nextInt(256));

  // UUID v4 version and variant bits.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}

class ApiService {
  final http.Client _client;
  final FlutterSecureStorage _secureStorage;

  ApiService({http.Client? client, FlutterSecureStorage? secureStorage})
    : _client = client ?? http.Client(),
      _secureStorage = secureStorage ?? const FlutterSecureStorage();

  // Development-only token storage.
  // The token disappears when the app is restarted.
  String? _token;
  final Map<String, String> _wearableClientEventIds = <String, String>{};

  bool get isAuthenticated => _token != null;

  String? get authToken => _token;

  String clientEventIdFor(String eventId) {
    final normalizedEventId = eventId.trim();
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-'
      r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    );
    return uuidPattern.hasMatch(normalizedEventId)
        ? normalizedEventId
        : (_wearableClientEventIds[normalizedEventId] ??=
              generateClientEventId());
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.loginEndpoint}');

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));

      final Map<String, dynamic> data;

      try {
        final decoded = jsonDecode(response.body);
        data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        return {
          'success': false,
          'status_code': response.statusCode,
          'message': 'The backend returned an unexpected response.',
        };
      }

      if (response.statusCode == 200 &&
          data['token'] is String &&
          (data['token'] as String).isNotEmpty) {
        _token = data['token'] as String;
        try {
          await _secureStorage.write(
            key: 'salamasphere_api_token',
            value: _token,
          );
        } catch (_) {
          // Authentication still succeeds if secure storage is unavailable on
          // a development platform; the in-memory token remains usable.
        }

        return {
          'success': true,
          'status_code': response.statusCode,
          'username': data['username'],
          'role': data['role'],
          'is_superuser': data['is_superuser'] == true,
          'authority_status': data['authority_status'],
          'message': 'Login successful.',
        };
      }

      return {
        'success': false,
        'status_code': response.statusCode,
        'message': data['detail'] ?? 'Login failed. Check your credentials.',
      };
    } catch (error) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to Django: $error',
      };
    }
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    String phoneNumber = '',
    required String role,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.registerEndpoint}');

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'username': username.trim(),
              'email': email.trim(),
              'password': password,
              'phone_number': phoneNumber.trim(),
              'role': role,
            }),
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final Map<String, dynamic> data = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};

      if (response.statusCode == 201) {
        return {
          'success': true,
          'status_code': response.statusCode,
          'username': data['username'],
          'role': data['role'],
          'authority_status': data['authority_status'],
          'message': data['message'] ?? 'Registration successful.',
        };
      }

      return {
        'success': false,
        'status_code': response.statusCode,
        'message': _registrationErrorMessage(data),
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to SalamaSphere. Check your connection and try again.',
      };
    }
  }

  String _registrationErrorMessage(Map<String, dynamic> data) {
    final messages = <String>[];

    for (final entry in data.entries) {
      final value = entry.value;

      if (value is List) {
        messages.addAll(value.map((item) => '$item'));
      } else if (value is String) {
        messages.add(value);
      } else if (value is Map) {
        messages.addAll(value.values.map((item) => '$item'));
      }
    }

    return messages.isEmpty
        ? 'Registration failed. Please check your details.'
        : messages.join('\n');
  }

  Future<Map<String, dynamic>> fetchIncidents() async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before retrieving incidents.',
      };
    }

    final uri = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.incidentsEndpoint}');

    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Token $_token',
            },
          )
          .timeout(const Duration(seconds: 15));

      final success = response.statusCode >= 200 && response.statusCode < 300;

      dynamic data;

      try {
        data = jsonDecode(response.body);
      } catch (_) {
        data = response.body;
      }

      return {
        'success': success,
        'status_code': response.statusCode,
        'data': data,
        'message': success
            ? 'Incidents retrieved successfully.'
            : 'Could not retrieve incidents.',
      };
    } catch (error) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to Django: $error',
      };
    }
  }

  Future<Map<String, dynamic>> fetchTrustedContacts() async {
    return _requestJson('GET', ApiConfig.trustedContactsEndpoint);
  }

  Future<Map<String, dynamic>> saveTrustedContact(
    Map<String, dynamic> contact, {
    String? id,
  }) async {
    final endpoint = id == null
        ? ApiConfig.trustedContactsEndpoint
        : '${ApiConfig.trustedContactsEndpoint}$id/';
    return _requestJson(id == null ? 'POST' : 'PUT', endpoint, body: contact);
  }

  Future<Map<String, dynamic>> deleteTrustedContact(String id) {
    return _requestJson('DELETE', '${ApiConfig.trustedContactsEndpoint}$id/');
  }

  Future<Map<String, dynamic>> dispatchIncidentNotifications(
    String incidentId,
  ) {
    return _requestJson(
      'POST',
      ApiConfig.incidentNotificationEndpoint(incidentId),
      body: const {'channel': 'sms'},
    );
  }

  Future<Map<String, dynamic>> fetchNotificationDeliveries(String incidentId) {
    return _requestJson(
      'GET',
      '${ApiConfig.notificationDeliveriesEndpoint}?incident=$incidentId',
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before using emergency notifications.',
      };
    }

    final request = http.Request(
      method,
      Uri.parse('${ApiConfig.baseUrl}$endpoint'),
    );
    request.headers.addAll({
      'Accept': 'application/json',
      'Authorization': 'Token $_token',
      if (body != null) 'Content-Type': 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);

    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
      final result = await http.Response.fromStream(response);
      dynamic decoded;
      try {
        decoded = jsonDecode(result.body);
      } catch (_) {
        decoded = result.body;
      }
      final success = response.statusCode >= 200 && response.statusCode < 300;
      return {
        'success': success,
        'status_code': response.statusCode,
        'data': decoded,
        'message': success
            ? 'Request completed.'
            : decoded is Map &&
                  (decoded['detail'] ?? decoded['message']) != null
            ? (decoded['detail'] ?? decoded['message']).toString()
            : 'The notification service request failed.',
      };
    } catch (error) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to the notification service: $error',
      };
    }
  }

  Future<Map<String, dynamic>> uploadIncidentAudio({
    required String incidentId,
    required List<int> bytes,
    String fileName = 'sos-audio.bin',
    String mimeType = 'application/octet-stream',
  }) async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before uploading incident audio.',
      };
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(
        '${ApiConfig.baseUrl}${ApiConfig.incidentAudioEndpoint(incidentId)}',
      ),
    );
    request.headers['Accept'] = 'application/json';
    request.headers['Authorization'] = 'Token $_token';
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
      final success = response.statusCode >= 200 && response.statusCode < 300;
      return {
        'success': success,
        'status_code': response.statusCode,
        'data': decoded,
        'message': success
            ? 'Incident audio uploaded successfully.'
            : 'Could not upload incident audio.',
      };
    } catch (error) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Network error while uploading incident audio: $error',
      };
    }
  }

  Future<Map<String, dynamic>> fetchIncidentAudio(String incidentId) async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before accessing incident audio.',
      };
    }

    try {
      final response = await _client
          .get(
            Uri.parse(
              '${ApiConfig.baseUrl}${ApiConfig.incidentAudioEndpoint(incidentId)}',
            ),
            headers: {
              'Accept': 'audio/*, application/octet-stream',
              'Authorization': 'Token $_token',
            },
          )
          .timeout(const Duration(seconds: 30));

      final success = response.statusCode >= 200 && response.statusCode < 300;
      return {
        'success': success,
        'status_code': response.statusCode,
        'bytes': success ? response.bodyBytes : null,
        'mime_type':
            response.headers['content-type'] ?? 'application/octet-stream',
        'message': success
            ? 'Incident audio retrieved successfully.'
            : 'Could not retrieve incident audio.',
      };
    } catch (error) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Network error while retrieving incident audio: $error',
      };
    }
  }

  Future<Map<String, dynamic>> createWearableSosIncident({
    required String eventId,
    required String deviceIdentifier,
    required DateTime occurredAt,
    String? eventType,
    String? recordingStatus,
    String threatLevel = 'high',
    double? latitude,
    double? longitude,
    double? locationAccuracy,
    DateTime? locationCapturedAt,
    String? locationSource,
  }) async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before submitting an SOS.',
      };
    }

    if (eventId.trim().isEmpty || deviceIdentifier.trim().isEmpty) {
      return {
        'success': false,
        'status_code': null,
        'message': 'The wearable event ID and device ID are required.',
      };
    }

    if (!{'low', 'medium', 'high'}.contains(threatLevel)) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Invalid threat level.',
      };
    }

    if ((latitude == null) != (longitude == null)) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Latitude and longitude must be supplied together.',
      };
    }

    // Retrying the same BLE event must not create a second incident. Use a
    // firmware UUID directly when possible; otherwise retain one generated
    // UUID for this event during the app session for UUID-backed APIs.
    final normalizedEventId = eventId.trim();
    final clientEventId = clientEventIdFor(normalizedEventId);

    final payload = <String, dynamic>{
      'client_event_id': clientEventId,
      'wearable_event_id': normalizedEventId,
      'device_identifier': deviceIdentifier,
      'source': 'wearable',
      'threat_level': threatLevel,
      'description': 'Wearable SOS event: $eventId',
      'occurred_at': occurredAt.toUtc().toIso8601String(),
      'is_sos': true,
    };

    if (eventType != null && eventType.trim().isNotEmpty) {
      payload['event_type'] = eventType.trim();
    }

    if (recordingStatus != null && recordingStatus.trim().isNotEmpty) {
      payload['recording_status'] = recordingStatus.trim();
    }

    if (latitude != null && longitude != null) {
      payload['latitude'] = latitude;
      payload['longitude'] = longitude;
      if (locationAccuracy != null) {
        payload['location_accuracy_m'] = locationAccuracy;
      }
      if (locationCapturedAt != null) {
        payload['location_captured_at'] =
            locationCapturedAt.toUtc().toIso8601String();
      }
      if (locationSource != null && locationSource.trim().isNotEmpty) {
        payload['location_source'] = locationSource.trim();
      }
    }

    final uri = Uri.parse('${ApiConfig.baseUrl}${ApiConfig.incidentsEndpoint}');

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Token $_token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final success = response.statusCode == 200 || response.statusCode == 201;

      final data = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};

      return {
        'success': success,
        'status_code': response.statusCode,
        'data': data,
        'message': success
            ? 'Wearable SOS incident saved.'
            : data.entries
                  .map((entry) => '${entry.key}: ${entry.value}')
                  .join('\n')
                  .isNotEmpty
            ? data.entries
                  .map((entry) => '${entry.key}: ${entry.value}')
                  .join('\n')
            : 'Could not save the wearable SOS incident.',
      };
    } catch (error) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Network error while submitting the SOS: $error',
      };
    }
  }

  Future<Map<String, dynamic>> fetchPendingAuthorityDocuments() async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before viewing verification documents.',
      };
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}'
      '${ApiConfig.adminVerificationDocumentsEndpoint}',
    );

    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Token $_token',
            },
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return {
          'success': false,
          'status_code': response.statusCode,
          'message': response.statusCode == 401 || response.statusCode == 403
              ? 'You are not authorized to review verification documents.'
              : 'Could not retrieve verification documents.',
        };
      }

      if (decoded is! List) {
        return {
          'success': false,
          'status_code': response.statusCode,
          'message': 'The backend returned an unexpected document list.',
        };
      }

      final documents = decoded
          .map(
            (item) => AuthorityVerificationDocument.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();

      return {
        'success': true,
        'status_code': response.statusCode,
        'documents': documents,
        'message': 'Verification documents retrieved successfully.',
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to SalamaSphere. Check your connection.',
      };
    }
  }

  Future<Map<String, dynamic>> reviewAuthorityDocument({
    required int documentId,
    required String decision,
    String reason = '',
  }) async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before reviewing documents.',
      };
    }

    if (decision != 'accepted' && decision != 'rejected') {
      return {
        'success': false,
        'status_code': null,
        'message': 'Invalid review decision.',
      };
    }

    if (decision == 'rejected' && reason.trim().isEmpty) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Provide a reason when rejecting a document.',
      };
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}'
      '${ApiConfig.adminVerificationDocumentDetailEndpoint(documentId)}',
    );

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Token $_token',
            },
            body: jsonEncode({'decision': decision, 'reason': reason.trim()}),
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final success = response.statusCode >= 200 && response.statusCode < 300;

      return {
        'success': success,
        'status_code': response.statusCode,
        'data': decoded,
        'message': success
            ? 'Document review recorded successfully.'
            : response.statusCode == 409
            ? 'This document has already been reviewed or the application is no longer pending.'
            : response.statusCode == 401 || response.statusCode == 403
            ? 'You are not authorized to review this document.'
            : 'Could not record the document review.',
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to SalamaSphere. Check your connection.',
      };
    }
  }

  Future<Map<String, dynamic>> uploadAuthorityDocument({
    required String documentType,
    required PlatformFile file,
  }) async {
    // Ensure the user is authenticated.
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before uploading a verification document.',
      };
    }

    // Supported document formats.
    const allowedExtensions = {'pdf', 'jpg', 'jpeg', 'png'};
    const maxFileSize = 5 * 1024 * 1024; // 5 MB

    // Get the file extension safely.
    final extension = file.name.contains('.')
        ? file.name.split('.').last.toLowerCase()
        : '';

    if (!allowedExtensions.contains(extension)) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Choose a PDF, JPG, JPEG, or PNG document.',
      };
    }

    // Determine the MIME type from the file extension.
    final MediaType contentType;

    switch (extension) {
      case 'pdf':
        contentType = MediaType('application', 'pdf');
        break;

      case 'jpg':
      case 'jpeg':
        contentType = MediaType('image', 'jpeg');
        break;

      case 'png':
        contentType = MediaType('image', 'png');
        break;

      default:
        return {
          'success': false,
          'status_code': null,
          'message': 'Unsupported document format.',
        };
    }

    // Read the selected file using the platform-independent picker API.
    late final List<int> fileBytes;

    try {
      final fileSize = await file.length();
      if (fileSize == null) {
        return {
          'success': false,
          'status_code': null,
          'message':
              'The selected file could not be read. Please select it again.',
        };
      }

      if (fileSize > maxFileSize) {
        return {
          'success': false,
          'status_code': null,
          'message': 'The document must not exceed 5 MB.',
        };
      }

      fileBytes = await file.readAsBytes();
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message':
            'The selected file could not be read. Please select it again.',
      };
    }

    // Validate the actual bytes read.
    if (fileBytes.isEmpty) {
      return {
        'success': false,
        'status_code': null,
        'message':
            'The selected document is empty. Please select another file.',
      };
    }

    if (fileBytes.length > maxFileSize) {
      return {
        'success': false,
        'status_code': null,
        'message': 'The document must not exceed 5 MB.',
      };
    }

    // Build the upload URL.
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.verificationDocumentsEndpoint}',
    );

    try {
      final request = http.MultipartRequest('POST', uri);

      request.headers.addAll({
        'Accept': 'application/json',
        'Authorization': 'Token $_token',
      });

      request.fields['document_type'] = documentType;

      // Attach the file once, with the correct declared MIME type.
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          fileBytes,
          filename: file.name,
          contentType: contentType,
        ),
      );

      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));

      final response = await http.Response.fromStream(streamedResponse);

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final success = response.statusCode >= 200 && response.statusCode < 300;

      return {
        'success': success,
        'status_code': response.statusCode,
        'data': decoded,
        'message': success
            ? 'Verification document submitted successfully.'
            : _registrationErrorMessage(
                decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
              ),
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not upload the document. Check your connection and try again.',
      };
    }
  }

  Future<Map<String, dynamic>> requestPasswordReset({
    required String email,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/accounts/password-reset/');

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'email': email.trim()}),
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final data = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};

      final success = response.statusCode >= 200 && response.statusCode < 300;

      return {
        'success': success,
        'status_code': response.statusCode,
        'message': success
            ? data['message'] ??
                  'If an active account matches that email, '
                      'reset instructions will be sent.'
            : data['detail'] ??
                  'Could not request a password reset. Please try again.',
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message':
            'Could not connect to SalamaSphere. '
            'Check your connection and try again.',
      };
    }
  }

  Future<Map<String, dynamic>> confirmPasswordReset({
    required String uid,
    required String token,
    required String newPassword,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/api/accounts/password-reset/confirm/',
    );

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'uid': uid.trim(),
              'token': token.trim(),
              'new_password': newPassword,
            }),
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final data = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};

      final success = response.statusCode >= 200 && response.statusCode < 300;

      String message;

      if (success) {
        message =
            data['message']?.toString() ??
            'Password reset successful. Please log in again.';
      } else {
        final detail = data['detail'];

        if (detail != null) {
          message = detail.toString();
        } else if (data['new_password'] is List) {
          message = (data['new_password'] as List)
              .map((item) => item.toString())
              .join('\n');
        } else {
          message =
              'Could not reset your password. '
              'Check the reset details and try again.';
        }
      }

      return {
        'success': success,
        'status_code': response.statusCode,
        'message': message,
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message':
            'Could not connect to SalamaSphere. '
            'Check your connection and try again.',
      };
    }
  }

  Future<Map<String, dynamic>> fetchAssignedAuthorityIncidents() async {
    if (_token == null) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Please log in before retrieving assigned incidents.',
        'incidents': <dynamic>[],
      };
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/api/incidents/authority/assigned/',
    );

    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Token $_token',
            },
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final success = response.statusCode >= 200 && response.statusCode < 300;

      if (success) {
        // Supports a normal DRF list and a paginated DRF response.
        final List<dynamic> incidents;

        if (decoded is List) {
          incidents = decoded;
        } else if (decoded is Map<String, dynamic> &&
            decoded['results'] is List) {
          incidents = decoded['results'] as List<dynamic>;
        } else {
          incidents = <dynamic>[];
        }

        return {
          'success': true,
          'status_code': response.statusCode,
          'incidents': incidents,
          'message': 'Assigned incidents retrieved successfully.',
        };
      }

      String message = 'Unable to retrieve assigned incidents.';

      if (decoded is Map<String, dynamic>) {
        message = (decoded['detail'] ?? decoded['message'] ?? message)
            .toString();
      }

      return {
        'success': false,
        'status_code': response.statusCode,
        'incidents': <dynamic>[],
        'message': message,
      };
    } catch (error) {
      return {
        'success': false,
        'status_code': null,
        'incidents': <dynamic>[],
        'message': 'Network error while retrieving assigned incidents.',
      };
    }
  }

  Future<Map<String, dynamic>> fetchAuthorityAccounts() async {
    if (_token == null) {
      return {
        'success': false,
        'message': 'Please log in before viewing authority accounts.',
        'accounts': <Map<String, dynamic>>[],
      };
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}${ApiConfig.adminAuthorityAccountsEndpoint}',
    );

    try {
      final response = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              'Authorization': 'Token $_token',
            },
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded is Map ? decoded['detail'] : null;

        return {
          'success': false,
          'status_code': response.statusCode,
          'message':
              detail?.toString() ?? 'Could not retrieve authority accounts.',
          'accounts': <Map<String, dynamic>>[],
        };
      }

      if (decoded is! List) {
        return {
          'success': false,
          'status_code': response.statusCode,
          'message': 'The backend returned an unexpected account list.',
          'accounts': <Map<String, dynamic>>[],
        };
      }

      final accounts = decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();

      return {
        'success': true,
        'status_code': response.statusCode,
        'accounts': accounts,
        'message': 'Authority accounts retrieved successfully.',
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to SalamaSphere.',
        'accounts': <Map<String, dynamic>>[],
      };
    }
  }

  Future<Map<String, dynamic>> reviewAuthorityApplication({
    required int userId,
    required String decision,
    String reason = '',
  }) async {
    if (_token == null) {
      return {
        'success': false,
        'message': 'Please log in before reviewing applications.',
      };
    }

    if (decision != 'approve' && decision != 'reject') {
      return {'success': false, 'message': 'Invalid application decision.'};
    }

    if (decision == 'reject' && reason.trim().isEmpty) {
      return {
        'success': false,
        'message': 'Provide a reason when rejecting an application.',
      };
    }

    final endpoint = decision == 'approve'
        ? ApiConfig.approveAuthorityEndpoint(userId)
        : ApiConfig.rejectAuthorityEndpoint(userId);

    final uri = Uri.parse('${ApiConfig.baseUrl}$endpoint');

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Token $_token',
            },
            body: jsonEncode({'reason': reason.trim()}),
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final success = response.statusCode >= 200 && response.statusCode < 300;

      final detail = decoded is Map
          ? (decoded['detail'] ?? decoded['message'])
          : null;

      return {
        'success': success,
        'status_code': response.statusCode,
        'data': decoded,
        'message': success
            ? (detail?.toString() ??
                  (decision == 'approve'
                      ? 'Authority application approved.'
                      : 'Authority application rejected.'))
            : detail?.toString() ??
                  'Could not update the authority application.',
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to SalamaSphere.',
      };
    }
  }

  Future<Map<String, dynamic>> updateAuthorityAccountStatus({
    required int userId,
    required String action,
    String reason = '',
  }) async {
    if (_token == null) {
      return {
        'success': false,
        'message': 'Please log in before managing authority accounts.',
      };
    }

    if (action != 'suspend' && action != 'reactivate') {
      return {'success': false, 'message': 'Invalid account action.'};
    }

    final uri = Uri.parse(
      '${ApiConfig.baseUrl}'
      '${ApiConfig.adminAuthorityAccountStatusEndpoint(userId)}',
    );

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Token $_token',
            },
            body: jsonEncode({'action': action, 'reason': reason.trim()}),
          )
          .timeout(const Duration(seconds: 15));

      dynamic decoded;

      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }

      final success = response.statusCode >= 200 && response.statusCode < 300;

      final detail = decoded is Map
          ? (decoded['detail'] ?? decoded['message'])
          : null;

      return {
        'success': success,
        'status_code': response.statusCode,
        'data': decoded,
        'message': success
            ? (detail?.toString() ??
                  (action == 'suspend'
                      ? 'Authority account suspended.'
                      : 'Authority account reactivated.'))
            : detail?.toString() ?? 'Could not update the authority account.',
      };
    } catch (_) {
      return {
        'success': false,
        'status_code': null,
        'message': 'Could not connect to SalamaSphere.',
      };
    }
  }

  void logout() {
    _token = null;
    unawaited(_secureStorage.delete(key: 'salamasphere_api_token'));
  }

  void dispose() {
    _client.close();
  }
}

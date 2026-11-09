import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:salamasphere_mobile/models/trusted_contact.dart';
import 'package:salamasphere_mobile/services/api_service.dart';
import 'package:salamasphere_mobile/services/notification_service.dart';

void main() {
  test('Kenyan phone numbers are normalized to international format', () {
    expect(normalizeKenyanPhoneNumber('0712 345 678'), '+254712345678');
    expect(normalizeKenyanPhoneNumber('712 345 678'), '+254712345678');
    expect(normalizeKenyanPhoneNumber('254712345678'), '+254712345678');
    expect(normalizeKenyanPhoneNumber('+254 712 345 678'), '+254712345678');
  });

  test(
    'saved trusted contact appears in the refreshed app contact list',
    () async {
      const contactId = 42;
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

        if (request.url.path == '/api/trusted-contacts/' &&
            request.method == 'POST') {
          final payload = jsonDecode(request.body) as Map<String, dynamic>;
          expect(payload['name'], 'Safety contact');
          expect(payload['phone_number'], '+254712345678');
          expect(payload['receive_sos_alerts'], isTrue);
          expect(payload['confirm_sos_consent'], isTrue);
          return http.Response(
            jsonEncode({
              'id': contactId,
              'name': payload['name'],
              'phone_number': payload['phone_number'],
              'receive_sos_alerts': true,
              'is_active': true,
              'consent_confirmed': true,
            }),
            201,
          );
        }

        if (request.url.path == '/api/trusted-contacts/' &&
            request.method == 'GET') {
          return http.Response(
            jsonEncode([
              {
                'id': contactId,
                'name': 'Safety contact',
                'phone_number': '+254712345678',
                'receive_sos_alerts': true,
                'is_active': true,
                'consent_confirmed': true,
              },
            ]),
            200,
          );
        }

        return http.Response('Unexpected request: ${request.url.path}', 404);
      });
      final apiService = ApiService(client: client);
      final notificationService = NotificationService(apiService);

      final login = await apiService.login(
        username: 'survivor',
        password: 'test-password',
      );
      expect(login['success'], isTrue);

      final saved = await notificationService.saveTrustedContact(
        const TrustedContact(
          name: 'Safety contact',
          phoneNumber: '+254712345678',
          consentConfirmed: true,
        ),
      );
      expect(saved['success'], isTrue);

      final contacts = await notificationService.getTrustedContacts();
      expect(contacts, hasLength(1));
      expect(contacts.single.id, '$contactId');
      expect(contacts.single.name, 'Safety contact');
      expect(contacts.single.phoneNumber, '+254712345678');
    },
  );
}

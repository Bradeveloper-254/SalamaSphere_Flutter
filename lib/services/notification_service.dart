import '../models/trusted_contact.dart';
import 'api_service.dart';

/// Client contract for the server-side emergency notification workflow.
/// Provider credentials and message submission must never be placed in the app.
class NotificationService {
  final ApiService api;

  const NotificationService(this.api);

  Future<List<TrustedContact>> getTrustedContacts() async {
    final result = await api.fetchTrustedContacts();
    if (result['success'] != true) {
      throw StateError(result['message'].toString());
    }
    final data = result['data'];
    final rows = data is List
        ? data
        : data is Map && data['results'] is List
        ? data['results'] as List
        : const <dynamic>[];
    return rows
        .whereType<Map>()
        .map((row) => TrustedContact.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<Map<String, dynamic>> saveTrustedContact(TrustedContact contact) {
    return api.saveTrustedContact(contact.toJson(), id: contact.id);
  }

  Future<Map<String, dynamic>> removeTrustedContact(String id) {
    return api.deleteTrustedContact(id);
  }

  Future<Map<String, dynamic>> deliveryStatus(String incidentId) =>
      api.fetchNotificationDeliveries(incidentId);
}

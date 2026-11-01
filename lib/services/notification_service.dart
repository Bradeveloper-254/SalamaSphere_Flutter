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

  /// Asks the backend to apply the configured rules, create a privacy-safe
  /// message, submit it through the configured Kenyan-capable provider, and
  /// persist provider delivery IDs/statuses. The returned deliveries are not
  /// treated as delivered unless the provider confirms delivery.
  Future<Map<String, dynamic>> notifyIncident(String incidentId) async {
    Map<String, dynamic> result = const {};
    for (var attempt = 0; attempt < 3; attempt++) {
      result = await api.dispatchIncidentNotifications(incidentId);
      if (result['success'] == true) return result;
      if (attempt < 2) {
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> deliveryStatus(String incidentId) =>
      api.fetchNotificationDeliveries(incidentId);
}

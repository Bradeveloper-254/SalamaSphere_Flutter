class ApiConfig {
  // Production Django API hosted on Render
  static const String baseUrl = 'https://salamasphere-api.onrender.com';

  static const String loginEndpoint = '/api/accounts/login/';
  static const String currentUserEndpoint = '/api/accounts/me/';
  static const String registerEndpoint = '/api/accounts/register/';
  static const String wearableDeviceRegistrationEndpoint =
      '/api/devices/register/';
  static const String incidentsEndpoint = '/api/incidents/';
  static String incidentEvidenceEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/evidence/';
  static String evidenceFileEndpoint(String evidenceId) =>
      '/api/evidence/$evidenceId/file/';
  static const String dashboardOverviewEndpoint = '/api/dashboard/overview/';
  static const String trustedContactsEndpoint = '/api/trusted-contacts/';
  static const String notificationDeliveriesEndpoint = '/api/notifications/';
  static const String notificationMessageRecipientsEndpoint =
      '/api/notifications/messages/recipients/';
  static const String notificationMessagesEndpoint =
      '/api/notifications/messages/';
  static const String verificationDocumentsEndpoint =
      '/api/accounts/verification-documents/';

  static const String adminVerificationDocumentsEndpoint =
      '/api/accounts/admin/verification-documents/';

  static String adminVerificationDocumentDetailEndpoint(int documentId) =>
      '$adminVerificationDocumentsEndpoint$documentId/';

  static String adminVerificationDocumentDownloadEndpoint(int documentId) =>
      '${adminVerificationDocumentDetailEndpoint(documentId)}download/';

  static const String adminUnassignedIncidentsEndpoint =
      '/api/incidents/admin/unassigned/';
  static const String adminIncidentAssignmentsEndpoint =
      '/api/incidents/admin/assignments/';
  static const String adminAssignableAuthoritiesEndpoint =
      '/api/incidents/admin/assignments/available-authorities/';
  static const String authorityPresenceEndpoint =
      '/api/incidents/authority/presence/';
  static String resolveAssignedIncidentEndpoint(String incidentId) =>
      '/api/incidents/authority/assigned/$incidentId/resolve/';

  static String notificationDetailEndpoint(String notificationId) =>
      '$notificationDeliveriesEndpoint$notificationId/';

  static String incidentDetailEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/';

  static String incidentAudioEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/audio/';

  static String incidentFollowUpNotesEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/notes/';

  static String incidentAuditEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/audit/';

  static const String authorityApplicationsEndpoint =
      '/api/accounts/authority-applications/';

  static String approveAuthorityEndpoint(int userId) =>
      '$authorityApplicationsEndpoint$userId/approve/';

  static String rejectAuthorityEndpoint(int userId) =>
      '$authorityApplicationsEndpoint$userId/reject/';

  static const String adminAuthorityAccountsEndpoint =
      '/api/accounts/admin/authorities/';

  static String adminAuthorityAccountStatusEndpoint(int userId) =>
      '$adminAuthorityAccountsEndpoint$userId/status/';
}

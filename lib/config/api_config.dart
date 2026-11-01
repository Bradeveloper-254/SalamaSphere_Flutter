class ApiConfig {
  static const String baseUrl = 'http://172.16.2.14:8000';

  static const String loginEndpoint = '/api/accounts/login/';
  static const String registerEndpoint = '/api/accounts/register/';
  static const String incidentsEndpoint = '/api/incidents/';
  static const String trustedContactsEndpoint =
      '/api/notifications/trusted-contacts/';
  static const String notificationDeliveriesEndpoint =
      '/api/notifications/deliveries/';
  static const String verificationDocumentsEndpoint =
      '/api/accounts/verification-documents/';

  // Keep your other existing endpoint definitions unchanged.
  static const String adminVerificationDocumentsEndpoint =
      '/api/accounts/admin/verification-documents/';

  static String adminVerificationDocumentDetailEndpoint(int documentId) =>
      '$adminVerificationDocumentsEndpoint$documentId/';

  static String adminVerificationDocumentDownloadEndpoint(int documentId) =>
      '${adminVerificationDocumentDetailEndpoint(documentId)}download/';

  static String incidentDetailEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/';

  static String incidentAudioEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/audio/';

  static String incidentNotificationEndpoint(String incidentId) =>
      '/api/incidents/$incidentId/notifications/';

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

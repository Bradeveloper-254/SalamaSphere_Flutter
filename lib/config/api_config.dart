class ApiConfig {
  // Production Django API hosted on Render
  static const String baseUrl = 'https://salamasphere-api.onrender.com';

  static const String loginEndpoint = '/api/accounts/login/';
  static const String currentUserEndpoint = '/api/accounts/me/';
  static const String registerEndpoint = '/api/accounts/register/';
  static const String incidentsEndpoint = '/api/incidents/';
  static const String trustedContactsEndpoint = '/api/trusted-contacts/';
  static const String notificationDeliveriesEndpoint =
      '/api/notifications/deliveries/';
  static const String verificationDocumentsEndpoint =
      '/api/accounts/verification-documents/';
  static const String evidenceVaultEndpoint = '/api/evidence-vault/';
  static const String privateMediaEndpoint = '/api/accounts/private-media/';

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

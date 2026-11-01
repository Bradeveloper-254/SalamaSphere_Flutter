class AuthorityVerificationDocument {
  final int id;
  final int authorityId;
  final String username;
  final String email;
  final String documentType;
  final String reviewStatus;
  final DateTime submittedAt;

  const AuthorityVerificationDocument({
    required this.id,
    required this.authorityId,
    required this.username,
    required this.email,
    required this.documentType,
    required this.reviewStatus,
    required this.submittedAt,
  });

  factory AuthorityVerificationDocument.fromJson(Map<String, dynamic> json) {
    return AuthorityVerificationDocument(
      id: _readInt(json['id'], 'id'),
      authorityId: _readInt(json['authority_id'], 'authority_id'),
      username: json['username']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      documentType: json['document_type']?.toString() ?? 'other',
      reviewStatus: json['review_status']?.toString() ?? 'pending',
      submittedAt: DateTime.parse(
        json['submitted_at']?.toString() ?? DateTime.now().toIso8601String(),
      ),
    );
  }

  static int _readInt(dynamic value, String field) {
    if (value is int) return value;

    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;

    throw FormatException('Invalid or missing $field');
  }
}

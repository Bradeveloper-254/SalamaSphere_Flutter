String normalizeKenyanPhoneNumber(String value) {
  final phone = value.replaceAll(RegExp(r'[\s()-]'), '');
  if (phone.startsWith('+')) return phone;
  if (RegExp(r'^254\d{9}$').hasMatch(phone)) return '+$phone';
  if (RegExp(r'^0\d{9}$').hasMatch(phone)) {
    return '+254${phone.substring(1)}';
  }
  if (RegExp(r'^[17]\d{8}$').hasMatch(phone)) return '+254$phone';
  return phone;
}

class TrustedContact {
  final String? id;
  final String name;
  final String phoneNumber;
  final String? email;
  final bool smsEnabled;
  final bool pushEnabled;
  final bool emailEnabled;
  final bool active;
  final bool consentConfirmed;
  final bool receiveVoiceCalls;
  final bool confirmVoiceConsent;
  final DateTime? voiceConsentConfirmedAt;

  const TrustedContact({
    this.id,
    required this.name,
    required this.phoneNumber,
    this.email,
    this.smsEnabled = true,
    this.pushEnabled = false,
    this.emailEnabled = false,
    this.active = true,
    this.consentConfirmed = false,
    this.receiveVoiceCalls = false,
    this.confirmVoiceConsent = false,
    this.voiceConsentConfirmedAt,
  });

  factory TrustedContact.fromJson(Map<String, dynamic> json) {
    return TrustedContact(
      id: json['id']?.toString(),
      name: (json['name'] ?? '').toString(),
      phoneNumber: (json['phone_number'] ?? json['phone'] ?? '').toString(),
      email: json['email']?.toString(),
      smsEnabled:
          (json['sms_enabled'] ?? json['receive_sos_alerts'] ?? true) == true,
      pushEnabled: json['push_enabled'] == true,
      emailEnabled: json['email_enabled'] == true,
      active: (json['active'] ?? json['is_active'] ?? true) == true,
      consentConfirmed: json['consent_confirmed'] == true,
      receiveVoiceCalls: json['receive_voice_calls'] == true,
      confirmVoiceConsent: json['confirm_voice_consent'] == true,
      voiceConsentConfirmedAt: json['voice_consent_confirmed_at'] == null
          ? null
          : DateTime.tryParse(json['voice_consent_confirmed_at'].toString()),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name.trim(),
    'phone_number': phoneNumber.trim(),
    'receive_sos_alerts': smsEnabled,
    'is_active': active,
    'confirm_sos_consent': consentConfirmed,
    'receive_voice_calls': receiveVoiceCalls,
    'confirm_voice_consent': confirmVoiceConsent,
  };
}

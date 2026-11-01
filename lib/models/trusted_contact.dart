class TrustedContact {
  final String? id;
  final String name;
  final String phoneNumber;
  final String? email;
  final bool smsEnabled;
  final bool pushEnabled;
  final bool emailEnabled;
  final bool active;

  const TrustedContact({
    this.id,
    required this.name,
    required this.phoneNumber,
    this.email,
    this.smsEnabled = true,
    this.pushEnabled = false,
    this.emailEnabled = false,
    this.active = true,
  });

  factory TrustedContact.fromJson(Map<String, dynamic> json) {
    return TrustedContact(
      id: json['id']?.toString(),
      name: (json['name'] ?? '').toString(),
      phoneNumber: (json['phone_number'] ?? json['phone'] ?? '').toString(),
      email: json['email']?.toString(),
      smsEnabled: json['sms_enabled'] != false,
      pushEnabled: json['push_enabled'] == true,
      emailEnabled: json['email_enabled'] == true,
      active: json['active'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name.trim(),
    'phone_number': phoneNumber.trim(),
    if (email != null && email!.trim().isNotEmpty) 'email': email!.trim(),
    'sms_enabled': smsEnabled,
    'push_enabled': pushEnabled,
    'email_enabled': emailEnabled,
    'active': active,
  };
}

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../admin_account_management_screen.dart';
import '../admin_verification_screen.dart';
import '../login_screen.dart';

class AdminDashboardScreen extends StatelessWidget {
  final ApiService apiService;
  final String username;

  const AdminDashboardScreen({
    super.key,
    required this.apiService,
    required this.username,
  });

  void _openVerification(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminVerificationScreen(apiService: apiService),
      ),
    );
  }

  void _openAccountManagement(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminAccountManagementScreen(apiService: apiService),
      ),
    );
  }

  void _logout(BuildContext context) {
    apiService.logout();

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(apiService: apiService)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFF176B5B);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Administrator'),
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Log out',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: primaryColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.admin_panel_settings_outlined,
                      color: Colors.white,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Admin Dashboard',
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Welcome, $username',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Manage authority verification and '
                      'system administration.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              const Text(
                'Administration',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 16),

              _AdminActionCard(
                icon: Icons.verified_user_outlined,
                title: 'Authority Verification',
                description:
                    'Review submitted verification documents '
                    'and record document review decisions.',
                onTap: () => _openVerification(context),
              ),

              const SizedBox(height: 12),

              _AdminActionCard(
                icon: Icons.manage_accounts_outlined,
                title: 'Account Management',
                description:
                    'Review authority applications, approve or '
                    'reject applicants, and suspend or reactivate '
                    'approved authority accounts.',
                onTap: () => _openAccountManagement(context),
              ),

              const SizedBox(height: 12),

              const _ComingSoonCard(
                icon: Icons.monitor_heart_outlined,
                title: 'System Monitoring',
                description:
                    'Monitor service health, synchronization '
                    'status, and audit activity.',
              ),

              const SizedBox(height: 24),

              const Text(
                'Security reminder',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),

              const SizedBox(height: 8),

              const Text(
                'Administrative access must be enforced by '
                'Django as well as by the app interface. '
                'Only authorized administrators should be able '
                'to review verification documents or change '
                'authority account status.',
                style: TextStyle(color: Colors.black54, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _AdminActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: const Icon(
          Icons.admin_panel_settings_outlined,
          size: 34,
          color: Color(0xFF176B5B),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(description),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 18),
        onTap: onTap,
      ),
    );
  }
}

class _ComingSoonCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _ComingSoonCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(icon, size: 34, color: Colors.grey),
        title: Text(title),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(description),
        ),
        trailing: const Chip(label: Text('Planned')),
      ),
    );
  }
}

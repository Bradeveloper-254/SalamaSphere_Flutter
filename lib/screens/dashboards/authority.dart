import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../login_screen.dart';
import '../assigned_cases_screen.dart';

class AuthorityDashboardScreen extends StatelessWidget {
  final ApiService apiService;
  final String username;

  const AuthorityDashboardScreen({
    super.key,
    required this.apiService,
    required this.username,
  });

  void _logout(BuildContext context) {
    apiService.logout();

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(apiService: apiService)),
      (route) => false,
    );
  }

  Widget _featureCard({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(description),
        ),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: onTap,
      ),
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$feature will be enabled after its backend permissions are configured.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Authority Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Log out',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: Colors.indigo,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.verified_user, color: Colors.white, size: 38),
                const SizedBox(height: 14),
                const Text(
                  'Authority Portal',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Welcome, $username',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Access to protected case information depends on '
                  'your approval status and assigned permissions.',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Authority Services',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 14),
          _featureCard(
            icon: Icons.folder_shared,
            title: 'Assigned Cases',
            description: 'View cases you are authorized to handle.',
            color: Colors.indigo,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AssignedCasesScreen(apiService: apiService),
                ),
              );
            },
          ),
          _featureCard(
            icon: Icons.security,
            title: 'Evidence Vault',
            description: 'Access authorized incident evidence and its integrity records.',
            color: Colors.teal,
            onTap: () => _showComingSoon(context, 'Evidence Vault'),
          ),
          _featureCard(
            icon: Icons.notifications_active,
            title: 'SOS Alerts',
            description: 'View alerts available to your authorized role.',
            color: Colors.deepOrange,
            onTap: () => _showComingSoon(context, 'SOS Alerts'),
          ),
          _featureCard(
            icon: Icons.account_circle,
            title: 'Account Information',
            description: 'Review your account and access status.',
            color: Colors.blueGrey,
            onTap: () => showDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Account Information'),
                content: Text('Username: $username\nRole: Authority'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Privacy reminder: Access only information necessary for '
            'your authorized duties. Do not share survivor evidence '
            'or personal details without proper authorization.',
            style: TextStyle(color: Colors.blueGrey, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

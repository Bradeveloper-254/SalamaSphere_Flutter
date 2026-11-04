import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../admin_account_management_screen.dart';
import '../admin_case_assignment_screen.dart';
import '../admin_verification_screen.dart';
import '../incident_dashboard_screen.dart';
import '../login_screen.dart';
import '../notification_inbox_screen.dart';

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

  void _openCaseAssignments(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminCaseAssignmentScreen(apiService: apiService),
      ),
    );
  }

  void _openNotifications(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationInboxScreen(apiService: apiService),
      ),
    );
  }

  void _openIncidentDashboard(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IncidentDashboardScreen(
          apiService: apiService,
          username: username,
          role: 'admin',
        ),
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
    const primaryColor = Color(0xFF102A43);
    const teal = Color(0xFF087F8C);
    const coral = Color(0xFFE76F51);

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

              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _AdminMetric(
                      icon: Icons.health_and_safety_outlined,
                      value: 'Healthy',
                      label: 'System',
                      color: teal,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AdminMetric(
                      icon: Icons.people_alt_outlined,
                      value: 'Users',
                      label: 'Statistics',
                      color: primaryColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AdminMetric(
                      icon: Icons.sync,
                      value: 'Queue',
                      label: 'Sync',
                      color: coral,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 28),

              const Text(
                'Administration',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
              ),

              const SizedBox(height: 16),

              _AdminActionCard(
                icon: Icons.dashboard_outlined,
                title: 'Incident Dashboard',
                description: 'Review incident metrics, evidence integrity, notifications, and audit activity.',
                onTap: () => _openIncidentDashboard(context),
              ),

              const SizedBox(height: 12),

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
                icon: Icons.assignment_ind_outlined,
                title: 'Assign Incidents',
                description: 'Assign open incidents to the nearest approved authorities who are available and not handling another case.',
                onTap: () => _openCaseAssignments(context),
              ),

              const SizedBox(height: 12),

              _AdminActionCard(
                icon: Icons.notifications_active_outlined,
                title: 'Notifications',
                description: 'Review updates about new incidents, case assignments, and resolutions.',
                onTap: () => _openNotifications(context),
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
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.white,
        indicatorColor: teal.withValues(alpha: 0.16),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard, color: teal),
            label: 'Overview',
          ),
          NavigationDestination(
            icon: Icon(Icons.admin_panel_settings_outlined),
            selectedIcon: Icon(Icons.admin_panel_settings, color: primaryColor),
            label: 'Admin',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_other_outlined),
            selectedIcon: Icon(Icons.devices, color: teal),
            label: 'Devices',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: coral),
            label: 'Settings',
          ),
        ],
        onDestinationSelected: (index) {
          if (index == 1) {
            _openAccountManagement(context);
          } else if (index == 2) {
            _showAdminMessage(
              context,
              'Device management is available from system monitoring.',
            );
          } else if (index == 3) {
            _showAdminMessage(
              context,
              'Settings include role permissions, audit logs and privacy controls.',
            );
          }
        },
      ),
    );
  }

  void _showAdminMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _AdminMetric extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _AdminMetric({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
        child: Column(
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(fontWeight: FontWeight.bold, color: color),
            ),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
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

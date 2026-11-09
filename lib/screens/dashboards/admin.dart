import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../admin_account_management_screen.dart';
import '../admin_case_assignment_screen.dart';
import '../admin_verification_screen.dart';
import '../incident_dashboard_screen.dart';
import '../login_screen.dart';
import '../notification_inbox_screen.dart';

class AdminDashboardScreen extends StatefulWidget {
  final ApiService apiService;
  final String username;

  const AdminDashboardScreen({
    super.key,
    required this.apiService,
    required this.username,
  });

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  Timer? _notificationRefreshTimer;
  int _unreadNotificationCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshNotificationCount();
    _notificationRefreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshNotificationCount(),
    );
  }

  @override
  void dispose() {
    _notificationRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshNotificationCount() async {
    final response = await widget.apiService.fetchNotifications();
    if (!mounted || response['success'] != true) return;

    final data = response['data'];
    final notifications = data is List
        ? data
        : data is Map && data['results'] is List
        ? data['results'] as List
        : null;
    if (notifications == null) return;

    final unreadCount = notifications
        .whereType<Map>()
        .where((notification) => notification['is_read'] != true)
        .length;
    if (unreadCount != _unreadNotificationCount) {
      setState(() => _unreadNotificationCount = unreadCount);
    }
  }

  void _openVerification(BuildContext context) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                AdminVerificationScreen(apiService: widget.apiService),
          ),
        )
        .then((_) => _refreshNotificationCount());
  }

  void _openAccountManagement(BuildContext context) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                AdminAccountManagementScreen(apiService: widget.apiService),
          ),
        )
        .then((_) => _refreshNotificationCount());
  }

  void _openCaseAssignments(BuildContext context) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                AdminCaseAssignmentScreen(apiService: widget.apiService),
          ),
        )
        .then((_) => _refreshNotificationCount());
  }

  Future<void> _openNotifications(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationInboxScreen(apiService: widget.apiService),
      ),
    );
    await _refreshNotificationCount();
  }

  void _openIncidentDashboard(BuildContext context) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => IncidentDashboardScreen(
              apiService: widget.apiService,
              username: widget.username,
              role: 'admin',
            ),
          ),
        )
        .then((_) => _refreshNotificationCount());
  }

  void _logout(BuildContext context) {
    widget.apiService.logout();

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => LoginScreen(apiService: widget.apiService),
      ),
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
            tooltip:
                'Notifications'
                '${_unreadNotificationCount > 0 ? ', $_unreadNotificationCount unread' : ''}',
            onPressed: () => _openNotifications(context),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_outlined),
                if (_unreadNotificationCount > 0)
                  Positioned(
                    top: -5,
                    right: -7,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _unreadNotificationCount > 99
                            ? '99+'
                            : '$_unreadNotificationCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
                      'Welcome, ${widget.username}',
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

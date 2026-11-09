import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/location_service.dart';
import '../login_screen.dart';
import '../assigned_cases_screen.dart';
import '../incident_dashboard_screen.dart';
import '../notification_inbox_screen.dart';

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

  void _openIncidentDashboard(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => IncidentDashboardScreen(
          apiService: apiService,
          username: username,
          role: 'authority',
        ),
      ),
    );
  }

  Future<void> _updateAvailability(
    BuildContext context, {
    required bool available,
  }) async {
    double? latitude;
    double? longitude;
    if (available) {
      final location = await LocationService().captureLocation();
      if (!context.mounted) return;
      if (location == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enable location permission and location services to become available.',
            ),
          ),
        );
        return;
      }
      latitude = location.latitude;
      longitude = location.longitude;
    }

    final response = await apiService.updateAuthorityPresence(
      isAvailable: available,
      latitude: latitude,
      longitude: longitude,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          response['success'] == true
              ? available
                    ? 'You are available for nearby case assignments.'
                    : 'You are unavailable for new case assignments.'
              : response['message']?.toString() ??
                    'Could not update your availability.',
        ),
      ),
    );
  }

  void _openNotifications(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            NotificationInboxScreen(apiService: apiService, canCompose: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF102A43);
    const teal = Color(0xFF087F8C);
    const coral = Color(0xFFE76F51);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Authority Dashboard'),
        backgroundColor: navy,
        foregroundColor: Colors.white,
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
              color: navy,
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
          Row(
            children: [
              Expanded(
                child: _statusTile(
                  Icons.folder_shared,
                  'Assigned',
                  'Cases',
                  teal,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statusTile(
                  Icons.priority_high,
                  'Urgent',
                  'Alerts',
                  coral,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _statusTile(
                  Icons.fact_check_outlined,
                  'Review',
                  'Status',
                  navy,
                ),
              ),
            ],
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
            onTap: () => _openIncidentDashboard(context),
          ),
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      CircleAvatar(child: Icon(Icons.location_on_outlined)),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Case availability',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Share your current location when you are ready to receive nearby case assignments.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () =>
                            _updateAvailability(context, available: true),
                        child: const Text('Available'),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            _updateAvailability(context, available: false),
                        child: const Text('Unavailable'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          _featureCard(
            icon: Icons.notifications_active,
            title: 'Notifications',
            description: 'View incident, assignment, and resolution updates.',
            color: Colors.deepOrange,
            onTap: () => _openNotifications(context),
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
            icon: Icon(Icons.folder_shared_outlined),
            selectedIcon: Icon(Icons.folder_shared, color: teal),
            label: 'Cases',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_active_outlined),
            selectedIcon: Icon(Icons.notifications_active, color: coral),
            label: 'Alerts',
          ),
          NavigationDestination(
            icon: Icon(Icons.fact_check_outlined),
            selectedIcon: Icon(Icons.fact_check, color: navy),
            label: 'Review',
          ),
        ],
        onDestinationSelected: (index) {
          if (index == 1) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AssignedCasesScreen(apiService: apiService),
              ),
            );
          } else if (index == 2) {
            _showComingSoon(context, 'Urgent alerts');
          } else if (index == 3) {
            _openIncidentDashboard(context);
          }
        },
      ),
    );
  }

  Widget _statusTile(IconData icon, String value, String label, Color color) {
    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
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

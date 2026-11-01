import 'package:flutter/material.dart';

import '../services/api_service.dart';

class DashboardScreen extends StatefulWidget {
  final ApiService apiService;
  final String username;

  const DashboardScreen({
    super.key,
    required this.apiService,
    required this.username,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool loading = false;

  String connectionStatus = 'Not checked';
  String incidentMessage = 'Checking for your incidents...';

  List<dynamic> incidents = [];

  @override
  void initState() {
    super.initState();
    loadIncidents();
  }

  Future<void> loadIncidents() async {
    if (loading) return;

    setState(() {
      loading = true;
      incidentMessage = 'Retrieving your incidents...';
    });

    final response = await widget.apiService.fetchIncidents();

    if (!mounted) return;

    final dynamic data = response['data'];
    final List<dynamic> retrievedIncidents = [];

    if (data is List) {
      retrievedIncidents.addAll(data);
    } else if (data is Map) {
      final results = data['results'];

      if (results is List) {
        retrievedIncidents.addAll(results);
      }
    }

    setState(() {
      loading = false;

      if (response['success'] == true) {
        incidents = retrievedIncidents;
        connectionStatus = 'Connected';
        incidentMessage = 'Retrieved ${incidents.length} incident(s).';
      } else {
        connectionStatus = 'Unavailable';
        incidentMessage =
            response['message']?.toString() ??
            'Could not retrieve incidents. Please try again.';
      }
    });
  }

  Future<void> logout() async {
    widget.apiService.logout();

    if (!mounted) return;

    Navigator.of(context).pop();
  }

  String readField(
    Map<String, dynamic> incident,
    List<String> possibleKeys, {
    String fallback = 'Not available',
  }) {
    for (final key in possibleKeys) {
      final value = incident[key];

      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }

    return fallback;
  }

  String formatDate(String value) {
    final parsed = DateTime.tryParse(value);

    if (parsed == null) return value;

    final local = parsed.toLocal();

    String twoDigits(int number) => number.toString().padLeft(2, '0');

    return '${local.year}-${twoDigits(local.month)}-'
        '${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  Color threatColor(String level) {
    switch (level.toLowerCase()) {
      case 'high':
      case 'critical':
        return Colors.red;
      case 'medium':
        return Colors.orange.shade800;
      case 'low':
        return Colors.green.shade700;
      default:
        return Colors.blueGrey;
    }
  }

  Widget buildStatusCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    Color? color,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: (color ?? Colors.blueGrey).withValues(
                alpha: 0.12,
              ),
              child: Icon(icon, color: color ?? Colors.blueGrey),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(value, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildIncidentCard(dynamic item) {
    if (item is! Map) {
      return const SizedBox.shrink();
    }

    final incident = Map<String, dynamic>.from(item);

    final id = readField(incident, [
      'id',
      'incident_id',
      'uuid',
    ], fallback: 'ID unavailable');

    final type = readField(incident, [
      'incident_type',
      'event_type',
      'incident_type_display',
    ], fallback: 'Safety incident');

    final createdAt = readField(incident, [
      'created_at',
      'received_at',
      'timestamp',
      'occurred_at',
    ]);

    final threat = readField(incident, [
      'threat_level',
      'initial_threat_level',
      'risk_level',
    ], fallback: 'Not assessed');

    final incidentStatus = readField(incident, [
      'status',
      'incident_status',
    ], fallback: 'Recorded');

    final isHighThreat =
        threat.toLowerCase() == 'high' || threat.toLowerCase() == 'critical';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: isHighThreat
                      ? Colors.red.withValues(alpha: 0.12)
                      : Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(
                    Icons.shield_outlined,
                    color: isHighThreat
                        ? Colors.red
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        type,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: $id',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: threatColor(threat).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    threat,
                    style: TextStyle(
                      color: threatColor(threat),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.access_time, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    createdAt == 'Not available'
                        ? 'Time not provided by server'
                        : formatDate(createdAt),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.assignment_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('Status: $incidentStatus')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = connectionStatus == 'Connected';

    return Scaffold(
      appBar: AppBar(
        title: const Text('SalamaSphere'),
        actions: [
          IconButton(
            onPressed: logout,
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: loadIncidents,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Your safety dashboard',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'Welcome, ${widget.username}. '
              'Review your incidents and connection status.',
            ),
            const SizedBox(height: 20),

            buildStatusCard(
              icon: connected ? Icons.cloud_done : Icons.cloud_outlined,
              title: 'Django backend',
              value: connectionStatus,
              subtitle: connected
                  ? 'Incident retrieval succeeded'
                  : 'Connection has not been confirmed',
              color: connected ? Colors.green : Colors.blueGrey,
            ),

            buildStatusCard(
              icon: Icons.bluetooth,
              title: 'Wearable',
              value: 'Not confirmed in this screen',
              subtitle:
                  'BLE connection and audio transfer must be checked '
                  'through the device integration.',
              color: Colors.blueGrey,
            ),

            buildStatusCard(
              icon: Icons.shield_outlined,
              title: 'Incidents retrieved',
              value: '${incidents.length}',
              subtitle: 'Records returned by the backend',
              color: Theme.of(context).colorScheme.primary,
            ),

            const SizedBox(height: 12),

            FilledButton.icon(
              onPressed: loading ? null : loadIncidents,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(
                loading ? 'Loading incidents...' : 'Refresh incidents',
              ),
            ),

            const SizedBox(height: 12),

            Text(
              incidentMessage,
              style: Theme.of(context).textTheme.bodyMedium,
            ),

            const SizedBox(height: 20),

            Text(
              'Recent incidents',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            if (!loading && incidents.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Icon(Icons.shield_outlined, size: 42),
                      const SizedBox(height: 10),
                      const Text(
                        'No incidents to display',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        connectionStatus == 'Connected'
                            ? 'The backend returned no incidents for '
                                  'this account.'
                            : 'Connect to the backend and refresh to '
                                  'check for incident records.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: loading ? null : loadIncidents,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),

            for (final incident in incidents) buildIncidentCard(incident),

            const SizedBox(height: 16),

            Card(
              child: ListTile(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Your evidence and privacy'),
                subtitle: const Text(
                  'Only share sensitive evidence with people you trust. '
                  'Check the selected recipients before sharing.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

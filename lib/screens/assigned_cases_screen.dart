import 'package:flutter/material.dart';

import '../services/api_service.dart';

class AssignedCasesScreen extends StatefulWidget {
  final ApiService apiService;

  const AssignedCasesScreen({super.key, required this.apiService});

  @override
  State<AssignedCasesScreen> createState() => _AssignedCasesScreenState();
}

class _AssignedCasesScreenState extends State<AssignedCasesScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _incidents = [];
  final Set<String> _resolvingIncidentIds = {};

  @override
  void initState() {
    super.initState();
    _loadIncidents();
  }

  Future<void> _loadIncidents() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    final result = await widget.apiService.fetchAssignedAuthorityIncidents();

    if (!mounted) return;

    if (result['success'] == true) {
      final rawIncidents = result['incidents'];
      if (rawIncidents is! List) {
        setState(() {
          _incidents = [];
          _isLoading = false;
          _errorMessage =
              'The backend returned an unexpected assigned cases response.';
        });
        return;
      }

      final incidents = <Map<String, dynamic>>[];
      for (final item in rawIncidents) {
        if (item is! Map || item.keys.any((key) => key is! String)) {
          setState(() {
            _incidents = [];
            _isLoading = false;
            _errorMessage =
                'The backend returned an invalid assigned case record.';
          });
          return;
        }
        incidents.add(Map<String, dynamic>.from(item));
      }

      setState(() {
        _incidents = incidents;
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage =
            result['message']?.toString() ?? 'Unable to load assigned cases.';
      });
    }
  }

  String _displayValue(dynamic value, {String fallback = 'Not provided'}) {
    if (value == null || value.toString().trim().isEmpty) {
      return fallback;
    }
    return value.toString();
  }

  String _formatDate(dynamic value) {
    if (value == null) return 'Date unavailable';

    final date = DateTime.tryParse(value.toString());
    if (date == null) return value.toString();

    final localDate = date.toLocal();

    String twoDigits(int number) => number.toString().padLeft(2, '0');

    return '${localDate.year}-${twoDigits(localDate.month)}-'
        '${twoDigits(localDate.day)} '
        '${twoDigits(localDate.hour)}:${twoDigits(localDate.minute)}';
  }

  Color _threatColor(String level) {
    switch (level.toLowerCase()) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange.shade800;
      case 'low':
        return Colors.green.shade700;
      default:
        return Colors.blueGrey;
    }
  }

  void _showIncidentDetails(Map<String, dynamic> incident) {
    final threat = _displayValue(incident['threat_level'], fallback: 'Unknown');
    final latitude = incident['latitude'];
    final longitude = incident['longitude'];

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Incident Details'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _detail('Incident ID', incident['id']),
              _detail('Source', incident['source']),
              _detail('Threat level', threat),
              _detail('Status', incident['status']),
              _detail('SOS alert', incident['is_sos'] == true ? 'Yes' : 'No'),
              _detail('Occurred at', _formatDate(incident['occurred_at'])),
              _detail('Received at', _formatDate(incident['received_at'])),
              _detail('Description', incident['description']),
              if (latitude != null && longitude != null) ...[
                _detail('Latitude', latitude),
                _detail('Longitude', longitude),
              ],
              _detail('Location source', incident['location_source']),
              _detail('Location accuracy (m)', incident['location_accuracy_m']),
              const SizedBox(height: 12),
              const Text(
                'Handle this information only as permitted by your role '
                'and assigned duties.',
                style: TextStyle(fontSize: 12, color: Colors.blueGrey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _resolveIncident(Map<String, dynamic> incident) async {
    final incidentId = incident['id']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Resolve this case?'),
        content: const Text(
          'This will close the incident and notify the people involved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Mark resolved'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _resolvingIncidentIds.add(incidentId));
    final result = await widget.apiService.resolveAssignedIncident(incidentId);
    if (!mounted) return;
    setState(() => _resolvingIncidentIds.remove(incidentId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result['message']?.toString() ??
              (result['success'] == true
                  ? 'Case marked as resolved.'
                  : 'Could not resolve this case.'),
        ),
      ),
    );
    if (result['success'] == true) await _loadIncidents();
  }

  Widget _detail(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 3),
          SelectableText(_displayValue(value)),
        ],
      ),
    );
  }

  Widget _buildIncidentCard(Map<String, dynamic> incident) {
    final threat = _displayValue(incident['threat_level'], fallback: 'Unknown');
    final status = _displayValue(incident['status'], fallback: 'Unknown');
    final isSos = incident['is_sos'] == true;

    final incidentId = incident['id']?.toString() ?? '';
    final isResolving = _resolvingIncidentIds.contains(incidentId);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: CircleAvatar(
              backgroundColor: isSos
                  ? Colors.red.withValues(alpha: 0.12)
                  : Colors.indigo.withValues(alpha: 0.12),
              child: Icon(
                isSos ? Icons.sos : Icons.folder_shared,
                color: isSos ? Colors.red : Colors.indigo,
              ),
            ),
            title: Text(
              isSos ? 'SOS Incident' : 'Assigned Incident',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ID: ${_displayValue(incident['id'])}'),
                  const SizedBox(height: 4),
                  Text('Received: ${_formatDate(incident['received_at'])}'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Chip(
                        label: Text(threat.toUpperCase()),
                        backgroundColor: _threatColor(threat)
                            .withValues(alpha: 0.12),
                        labelStyle: TextStyle(
                          color: _threatColor(threat),
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                      Chip(label: Text(status.toUpperCase())),
                    ],
                  ),
                  if ((incident['description'] ?? '')
                      .toString()
                      .trim()
                      .isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      incident['description'].toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showIncidentDetails(incident),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: isResolving
                    ? null
                    : () => _resolveIncident(incident),
                icon: isResolving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: const Text('Mark resolved'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Assigned Cases'),
        actions: [
          IconButton(
            tooltip: 'Refresh cases',
            onPressed: _isLoading ? null : _loadIncidents,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off,
                      size: 48,
                      color: Colors.blueGrey,
                    ),
                    const SizedBox(height: 16),
                    Text(_errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _loadIncidents,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            )
          : _incidents.isEmpty
          ? RefreshIndicator(
              onRefresh: _loadIncidents,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: const [
                  SizedBox(height: 100),
                  Icon(Icons.folder_open, size: 64, color: Colors.blueGrey),
                  SizedBox(height: 16),
                  Text(
                    'No Assigned Cases',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Cases assigned to your approved account will '
                    'appear here.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadIncidents,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    '${_incidents.length} assigned '
                    '${_incidents.length == 1 ? 'case' : 'cases'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  ..._incidents.map(_buildIncidentCard),
                ],
              ),
            ),
    );
  }
}

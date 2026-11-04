import 'package:flutter/material.dart';

import '../services/api_service.dart';

class AdminCaseAssignmentScreen extends StatefulWidget {
  final ApiService apiService;

  const AdminCaseAssignmentScreen({super.key, required this.apiService});

  @override
  State<AdminCaseAssignmentScreen> createState() =>
      _AdminCaseAssignmentScreenState();
}

class _AdminCaseAssignmentScreenState extends State<AdminCaseAssignmentScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _incidents = [];
  final Set<String> _assigning = {};

  @override
  void initState() {
    super.initState();
    _loadIncidents();
  }

  Future<void> _loadIncidents() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    final response = await widget.apiService.fetchAdminUnassignedIncidents();
    if (!mounted) return;
    final data = response['data'];
    if (response['success'] == true && data is List) {
      setState(() {
        _incidents = data
            .whereType<Map>()
            .where((item) => item.keys.every((key) => key is String))
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage =
            response['message']?.toString() ??
            'Could not load unassigned incidents.';
      });
    }
  }

  Future<void> _chooseAuthority(Map<String, dynamic> incident) async {
    final incidentId = incident['id']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;
    final response = await widget.apiService.fetchAssignableAuthorities(
      incidentId,
    );
    if (!mounted) return;
    final data = response['data'];
    if (response['success'] != true || data is! List) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            response['message']?.toString() ??
                'Could not find nearby available authorities.',
          ),
        ),
      );
      return;
    }

    final authorities = data
        .whereType<Map>()
        .where((item) => item.keys.every((key) => key is String))
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    if (authorities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No available authority is nearby for this incident.'),
        ),
      );
      return;
    }

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Available authorities nearby',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            for (final authority in authorities)
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.verified_user_outlined),
                ),
                title: Text(authority['username']?.toString() ?? 'Authority'),
                subtitle: Text(
                  '${authority['distance_km'] ?? '?'} km away'
                  '${(authority['phone_number'] ?? '').toString().isEmpty ? '' : ' · ${authority['phone_number']}'}',
                ),
                onTap: () => Navigator.pop(context, authority),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;

    setState(() => _assigning.add(incidentId));
    final result = await widget.apiService.assignIncident(
      incidentId: incidentId,
      authorityId: int.parse(selected['id'].toString()),
    );
    if (!mounted) return;
    setState(() => _assigning.remove(incidentId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result['message']?.toString() ??
              (result['success'] == true
                  ? 'Incident assigned.'
                  : 'Could not assign incident.'),
        ),
      ),
    );
    if (result['success'] == true) await _loadIncidents();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Assign Cases'),
        actions: [
          IconButton(
            tooltip: 'Refresh incidents',
            onPressed: _isLoading ? null : _loadIncidents,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading && _incidents.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null && _incidents.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _loadIncidents,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadIncidents,
              child: _incidents.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 120),
                        Icon(Icons.assignment_turned_in_outlined, size: 56),
                        SizedBox(height: 12),
                        Center(child: Text('No unassigned incidents.')),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(12),
                      itemCount: _incidents.length,
                      itemBuilder: (context, index) {
                        final incident = _incidents[index];
                        final id = incident['id']?.toString() ?? '';
                        final hasLocation =
                            incident['latitude'] != null &&
                            incident['longitude'] != null;
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    incident['is_sos'] == true
                                        ? Icons.sos
                                        : Icons.warning_amber,
                                    color: incident['is_sos'] == true
                                        ? Colors.red
                                        : Colors.orange,
                                  ),
                                  title: Text(
                                    incident['is_sos'] == true
                                        ? 'SOS incident'
                                        : 'Incident ${id.length > 8 ? id.substring(0, 8) : id}',
                                  ),
                                  subtitle: Text(
                                    '${incident['threat_level'] ?? 'Unknown'} priority'
                                    '${incident['description'] == null || incident['description'].toString().isEmpty ? '' : '\n${incident['description']}'}',
                                  ),
                                ),
                                if (!hasLocation)
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      'This incident has no location, so a nearby authority cannot be selected.',
                                      style: TextStyle(color: Colors.orange),
                                    ),
                                  ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: FilledButton.icon(
                                    onPressed:
                                        !hasLocation ||
                                            id.isEmpty ||
                                            _assigning.contains(id)
                                        ? null
                                        : () => _chooseAuthority(incident),
                                    icon: _assigning.contains(id)
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.person_add_alt_1),
                                    label: const Text(
                                      'Assign nearby authority',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

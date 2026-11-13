import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../services/location_service.dart';
import '../widgets/incident_media.dart';

class IncidentDashboardScreen extends StatefulWidget {
  final ApiService apiService;
  final String username;
  final String role;

  const IncidentDashboardScreen({
    super.key,
    required this.apiService,
    required this.username,
    required this.role,
  });

  @override
  State<IncidentDashboardScreen> createState() =>
      _IncidentDashboardScreenState();
}

class _IncidentDashboardScreenState extends State<IncidentDashboardScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _incidents = [];

  bool get _isTrustedContact => widget.role == 'trusted_contact';

  bool get _canAddNotes => <String>{
    'admin',
    'authority',
    'responder',
    'designated_responder',
    'survivor',
    'victim',
  }.contains(widget.role);

  @override
  void initState() {
    super.initState();
    _loadIncidents();
  }

  Future<void> _loadIncidents() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final result = <String, dynamic>{};
    if (<String>{
      'authority',
      'responder',
      'designated_responder',
    }.contains(widget.role)) {
      final assigned = await widget.apiService
          .fetchAssignedAuthorityIncidents();
      result['success'] = assigned['success'];
      result['message'] = assigned['message'];
      result['data'] = assigned['incidents'];
    } else {
      final response = await widget.apiService.fetchIncidents();
      result['success'] = response['success'];
      result['message'] = response['message'];
      result['data'] = response['data'];
    }

    if (!mounted) return;

    if (result['success'] != true) {
      setState(() {
        _loading = false;
        _error = result['message']?.toString() ?? 'Unable to load incidents.';
      });
      return;
    }

    final data = result['data'];
    final raw = data is Map ? data['results'] : data;
    final records = raw is List
        ? raw.whereType<Map>().map((item) => Map<String, dynamic>.from(item))
        : <Map<String, dynamic>>[];

    setState(() {
      _incidents = records.toList();
      _loading = false;
    });
  }

  String _value(
    Map<String, dynamic> incident,
    List<String> keys, {
    String fallback = 'Not available',
  }) {
    for (final key in keys) {
      final value = incident[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }
    return fallback;
  }

  String _date(Map<String, dynamic> incident, List<String> keys) {
    final raw = _value(incident, keys);
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  bool _isHighPriority(Map<String, dynamic> incident) {
    final threat = _value(incident, [
      'threat_level',
      'risk_level',
    ]).toLowerCase();
    return threat == 'high' || threat == 'critical';
  }

  bool _isPending(Map<String, dynamic> incident) {
    final status = _value(incident, [
      'sync_state',
      'sync_status',
      'status',
    ]).toLowerCase();
    return status == 'pending' || status == 'queued' || status == 'failed';
  }

  String _verificationStatus(Map<String, dynamic> incident) {
    return _value(
      incident,
      [
        'evidence_verification_status',
        'verification_status',
        'integrity_status',
      ],
      fallback: incident['audio_sha256'] != null ? 'Recorded hash' : 'Pending',
    );
  }

  Color _priorityColor(Map<String, dynamic> incident) =>
      _isHighPriority(incident) ? Colors.red : Colors.blueGrey;

  Future<void> _openDetails(Map<String, dynamic> incident) async {
    final id = _value(incident, ['id', 'incident_id', 'uuid']);
    if (id == 'Not available') return;
    await widget.apiService.recordIncidentAudit(
      incidentId: id,
      action: 'view_incident_dashboard',
      metadata: {'role': widget.role},
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _IncidentDetailsSheet(
        incident: incident,
        apiService: widget.apiService,
        role: widget.role,
        canAddNotes: _canAddNotes,
        isTrustedContact: _isTrustedContact,
        onAddNote: (note) => _addNote(id, note),
        onLoadNotifications: () => _loadNotifications(id),
      ),
    );
  }

  Future<List<dynamic>> _loadNotifications(String incidentId) async {
    final response = await widget.apiService.fetchNotificationDeliveries(
      incidentId,
    );
    final data = response['data'];
    return data is List
        ? data
        : data is Map && data['results'] is List
        ? data['results'] as List
        : <dynamic>[];
  }

  Future<void> _addNote(String incidentId, String note) async {
    final response = await widget.apiService.addIncidentFollowUpNote(
      incidentId: incidentId,
      note: note,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          response['success'] == true
              ? 'Follow-up note recorded.'
              : response['message']?.toString() ?? 'Could not save note.',
        ),
      ),
    );
  }

  Widget _stat(String label, int value, IconData icon, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 6),
              Text('$value', style: Theme.of(context).textTheme.titleLarge),
              Text(label, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _incidents.where(_isPending).length;
    final highPriority = _incidents.where(_isHighPriority).length;
    final verified = _incidents
        .where(
          (item) => _verificationStatus(item).toLowerCase().contains('verif'),
        )
        .length;
    final recent = _incidents.take(5).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Incident Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh incidents',
            onPressed: _loading ? null : _loadIncidents,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : RefreshIndicator(
              onRefresh: _loadIncidents,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Welcome, ${widget.username}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text('Role: ${widget.role.replaceAll('_', ' ')}'),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _stat(
                        'Total',
                        _incidents.length,
                        Icons.folder,
                        Colors.indigo,
                      ),
                      const SizedBox(width: 8),
                      _stat(
                        'Pending sync',
                        pending,
                        Icons.sync_problem,
                        Colors.orange,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      _stat(
                        'High priority',
                        highPriority,
                        Icons.priority_high,
                        Colors.red,
                      ),
                      const SizedBox(width: 8),
                      _stat(
                        'Evidence verified',
                        verified,
                        Icons.verified,
                        Colors.green,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Recent incidents',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (recent.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('No permitted incidents found.'),
                      ),
                    ),
                  ...recent.map(
                    (incident) => Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _priorityColor(incident)
                              .withValues(alpha: 0.12),
                          child: Icon(
                            Icons.shield_outlined,
                            color: _priorityColor(incident),
                          ),
                        ),
                        title: Text(
                          _value(incident, [
                            'incident_type_display',
                            'event_type',
                            'source',
                          ], fallback: 'Incident'),
                        ),
                        subtitle: Text(
                          'ID: ${_value(incident, ['id', 'incident_id', 'uuid'])}\n'
                          'Received: ${_date(incident, ['received_at', 'created_at'])}\n'
                          'Threat: ${_value(incident, ['threat_level', 'risk_level'])}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openDetails(incident),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _IncidentDetailsSheet extends StatefulWidget {
  final Map<String, dynamic> incident;
  final ApiService apiService;
  final String role;
  final bool canAddNotes;
  final bool isTrustedContact;
  final Future<void> Function(String note) onAddNote;
  final Future<List<dynamic>> Function() onLoadNotifications;

  const _IncidentDetailsSheet({
    required this.incident,
    required this.apiService,
    required this.role,
    required this.canAddNotes,
    required this.isTrustedContact,
    required this.onAddNote,
    required this.onLoadNotifications,
  });

  @override
  State<_IncidentDetailsSheet> createState() => _IncidentDetailsSheetState();
}

class _IncidentDetailsSheetState extends State<_IncidentDetailsSheet> {
  final _noteController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<dynamic>? _notifications;
  bool _loadingNotifications = false;

  String _value(List<String> keys, {String fallback = 'Not available'}) {
    for (final key in keys) {
      final value = widget.incident[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }
    return fallback;
  }

  @override
  void dispose() {
    _noteController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _playIncidentAudio() async {
    final id = _value(['id', 'incident_id', 'uuid']);
    if (id == 'Not available') return;
    final result = await widget.apiService.fetchIncidentAudio(id);
    if (!mounted) return;
    if (result['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result['message']?.toString() ?? 'Could not load incident audio.',
          ),
        ),
      );
      return;
    }

    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(
        BytesSource(
          Uint8List.fromList(List<int>.from(result['bytes'] as List)),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play incident audio: $error')),
      );
    }
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          SelectableText(value),
        ],
      ),
    );
  }

  Widget _locationLink() {
    final latitude = widget.incident['latitude'];
    final longitude = widget.incident['longitude'];
    final uri = googleMapsUriForCoordinates(latitude, longitude);
    if (uri == null) {
      return _detail('Location', _value(['location_display', 'location']));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Location', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          TextButton.icon(
            onPressed: () async {
              final opened = await launchUrl(
                uri,
                mode: LaunchMode.externalApplication,
              );
              if (!opened && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Unable to open the location in Google Maps.',
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.map_outlined),
            label: const Text('Open in Google Maps'),
          ),
        ],
      ),
    );
  }

  Future<void> _showNotifications() async {
    setState(() => _loadingNotifications = true);
    final id = _value(['id', 'incident_id', 'uuid']);
    final notifications = await widget.onLoadNotifications();
    if (!mounted) return;
    setState(() {
      _notifications = notifications;
      _loadingNotifications = false;
    });
    if (notifications.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No notification history returned.')),
      );
    }
    debugPrint('Notification history loaded for $id');
  }

  @override
  Widget build(BuildContext context) {
    final audioStatus = _value(
      ['audio_status', 'recording_status'],
      fallback: widget.incident['audio_url'] != null
          ? 'Available'
          : widget.incident['audio_available'] == true
          ? 'Available'
          : 'Not available',
    );
    final verification = _value(
      [
        'evidence_verification_status',
        'verification_status',
        'integrity_status',
      ],
      fallback: widget.incident['audio_sha256'] != null
          ? 'Hash recorded'
          : 'Pending',
    );
    final canAccessAudio =
        !widget.isTrustedContact || widget.incident['can_view_audio'] == true;
    final canAccessEvidence =
        !widget.isTrustedContact ||
        widget.incident['can_view_evidence'] == true;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Incident details',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              _detail(
                'Incident identifier',
                _value(['id', 'incident_id', 'uuid']),
              ),
              _detail(
                'Activation timestamp',
                _value(['activated_at', 'occurred_at']),
              ),
              _detail(
                'Receipt timestamp',
                _value(['received_at', 'created_at']),
              ),
              _locationLink(),
              _detail('Threat level', _value(['threat_level', 'risk_level'])),
              _detail('Audio recording', audioStatus),
              _detail('SHA-256', _value(['audio_sha256', 'evidence_sha256'])),
              _detail('Evidence verification', verification),
              _detail(
                'Synchronization state',
                _value(['sync_state', 'sync_status'], fallback: 'Unknown'),
              ),
              _detail(
                'Metadata acknowledgement',
                _value(['metadata_ack_status'], fallback: 'Unknown'),
              ),
              _detail(
                'Audio acknowledgement',
                _value(['audio_ack_status'], fallback: 'Unknown'),
              ),
              if (canAccessEvidence)
                IncidentEvidenceList(
                  apiService: widget.apiService,
                  incidentId: _value(['id', 'incident_id', 'uuid']),
                ),
              _detail(
                'Notification acknowledgement',
                _value(['notification_ack_status'], fallback: 'Unknown'),
              ),
              if (canAccessAudio &&
                  audioStatus.toLowerCase() != 'not available')
                Card(
                  child: ListTile(
                    leading: Icon(Icons.lock_outline),
                    title: Text('Recorded audio is available'),
                    subtitle: TextButton.icon(
                      onPressed: _playIncidentAudio,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play recording'),
                    ),
                  ),
                ),
              if (!canAccessAudio)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.lock),
                    title: const Text('Audio restricted'),
                    subtitle: Text(
                      'This trusted contact has no recording permission for this incident.',
                    ),
                  ),
                ),
              if (!canAccessEvidence)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.lock),
                    title: const Text('Incident media restricted'),
                    subtitle: Text(
                      'This trusted contact has no media permission for this incident.',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _loadingNotifications ? null : _showNotifications,
                icon: const Icon(Icons.notifications_outlined),
                label: Text(
                  _loadingNotifications
                      ? 'Loading notification history...'
                      : 'Inspect notification history',
                ),
              ),
              if (_notifications != null)
                ..._notifications!.map(
                  (item) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.mark_email_read_outlined),
                    title: Text(
                      item is Map
                          ? (item['channel'] ??
                                    item['status'] ??
                                    'Notification')
                                .toString()
                          : item.toString(),
                    ),
                    subtitle: Text(
                      item is Map
                          ? (item['delivered_at'] ?? item['created_at'] ?? '')
                                .toString()
                          : '',
                    ),
                  ),
                ),
              if (widget.canAddNotes) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _noteController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Authorized follow-up note',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () async {
                    final note = _noteController.text.trim();
                    if (note.isEmpty) return;
                    await widget.onAddNote(note);
                    if (mounted) _noteController.clear();
                  },
                  icon: const Icon(Icons.note_add_outlined),
                  label: const Text('Record follow-up note'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

import '../../models/wearable_event.dart';
import '../../services/api_service.dart';
import '../../services/ble_service.dart';
import '../../services/incident_sync_service.dart';
import '../../services/local_database_service.dart';
import '../../services/location_service.dart';
import '../../services/notification_service.dart';
import '../../models/trusted_contact.dart';
import '../login_screen.dart';

class VictimDashboardScreen extends StatefulWidget {
  final ApiService apiService;
  final String username;

  const VictimDashboardScreen({
    super.key,
    required this.apiService,
    required this.username,
  });

  @override
  State<VictimDashboardScreen> createState() => _VictimDashboardScreenState();
}

class _VictimDashboardScreenState extends State<VictimDashboardScreen> {
  bool _loading = true;
  bool _connected = false;

  String _message = 'Loading your incidents...';
  List<dynamic> _incidents = [];
  final Map<String, Map<String, Object?>> _localAudioByEventId = {};
  final AudioPlayer _audioPlayer = AudioPlayer();

  // Wearable connection state.
  final BleService _bleService = BleService();
  final LocationService _locationService = LocationService();
  final LocalDatabaseService _localDatabase = LocalDatabaseService.instance;
  late final IncidentSyncService _incidentSync;
  late final NotificationService _notifications;
  StreamSubscription<WearableEvent>? _wearableSubscription;
  StreamSubscription<String>? _recordingStatusSubscription;
  StreamSubscription<Map<String, dynamic>>? _audioMetadataSubscription;
  StreamSubscription<List<int>>? _audioChunkSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool _connectingWearable = false;
  bool _wearableConnected = false;
  bool _submittingSos = false;

  String _wearableMessage = 'Wearable not connected';
  Map<String, dynamic>? _audioTransferMetadata;
  int? _expectedAudioBytes;
  String? _activeEventClientId;
  final List<int> _audioBytes = <int>[];
  bool _recordingComplete = false;
  bool _audioSaveInProgress = false;

  // Prevent the same event notification from being processed
  // more than once during this screen session.
  final Set<String> _processedEventIds = <String>{};

  @override
  void initState() {
    super.initState();
    _incidentSync = IncidentSyncService(database: _localDatabase);
    _notifications = NotificationService(widget.apiService);
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      _retryPendingUploads,
    );
    _loadIncidents();
  }

  Future<void> _retryPendingUploads(List<ConnectivityResult> result) async {
    if (result.contains(ConnectivityResult.none) ||
        widget.apiService.authToken == null) {
      return;
    }

    final token = widget.apiService.authToken!;
    await _incidentSync.synchronizePendingIncidents(token: token);
    await _incidentSync.synchronizePendingAudio(
      upload: widget.apiService.uploadIncidentAudio,
    );
    await _notifySynchronizedIncidents();
    if (mounted) await _loadIncidents();
  }

  Future<void> _notifySynchronizedIncidents() async {
    final incidents = await _localDatabase.getAllIncidents();
    for (final incident in incidents) {
      final serverId = incident['server_incident_id']?.toString();
      if (serverId == null || serverId.isEmpty) continue;
      final notified = incident['notification_status']?.toString();
      if (notified == 'sent' || notified == 'delivered') continue;
      final result = await _notifications.notifyIncident(serverId);
      // Notification delivery is ultimately confirmed by provider callbacks
      // on the backend; this only records that dispatch was attempted in the
      // client session. The server remains the source of truth.
      if (result['success'] == true) break;
    }
  }

  Future<void> _loadIncidents() async {
    if (_loading && _incidents.isNotEmpty) return;

    if (mounted) {
      setState(() {
        _loading = true;
        _message = 'Retrieving your incident history...';
      });
    }

    try {
      final response = await widget.apiService.fetchIncidents();

      if (!mounted) return;

      final dynamic data = response['data'];
      final List<dynamic> retrieved = [];

      if (data is List) {
        retrieved.addAll(data);
      } else if (data is Map) {
        final results = data['results'];

        if (results is List) {
          retrieved.addAll(results);
        }
      }

      // Keep pending and failed incidents visible while they wait for a
      // successful Django synchronization.
      final pending = await _localDatabase.getPendingIncidents();
      final remoteIds = retrieved
          .whereType<Map>()
          .map((item) => item['id']?.toString())
          .whereType<String>()
          .toSet();
      retrieved.addAll(
        pending.where((item) {
          final id = item['client_event_id']?.toString();
          return id == null || !remoteIds.contains(id);
        }),
      );

      _localAudioByEventId.clear();
      for (final incident in await _localDatabase.getAllIncidents()) {
        final clientId = incident['client_event_id']?.toString();
        if (clientId == null) continue;
        final audio = await _localDatabase.getIncidentAudio(clientId);
        if (audio != null) _localAudioByEventId[clientId] = audio;
      }

      setState(() {
        _loading = false;
        _connected = response['success'] == true;

        if (_connected) {
          _incidents = retrieved;
          _message = retrieved.isEmpty
              ? 'No incidents have been recorded for your account yet.'
              : '${retrieved.length} incident(s) found.';
        } else {
          _message =
              response['message']?.toString() ??
              'Unable to retrieve incidents. Please try again.';
        }
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loading = false;
        _connected = false;
        _message = 'Could not connect to the server. Check your connection.';
      });
    }
  }

  // Connect to the ESP32-S3 wearable.
  Future<void> _connectWearable() async {
    if (_connectingWearable || _wearableConnected) return;

    setState(() {
      _connectingWearable = true;
      _wearableMessage = 'Searching for SalamaSphere...';
    });

    try {
      // Subscribe before connecting so an early notification
      // is less likely to be missed.
      _wearableSubscription ??= _bleService.events.listen(
        _handleWearableEvent,
        onError: (Object error) {
          if (!mounted) return;

          setState(() {
            _wearableMessage = 'Wearable event error: $error';
          });
        },
      );
      _recordingStatusSubscription ??= _bleService.recordingStatuses.listen(
        _handleRecordingStatus,
      );
      _audioMetadataSubscription ??= _bleService.audioMetadata.listen((
        metadata,
      ) {
        if (!mounted) return;
        final expected =
            metadata['size'] ??
            metadata['length'] ??
            metadata['total_bytes'] ??
            metadata['file_size'];
        setState(() {
          _audioTransferMetadata = metadata;
          _expectedAudioBytes = int.tryParse(expected?.toString() ?? '');
        });
        if (_expectedAudioBytes != null &&
            _audioBytes.length >= _expectedAudioBytes!) {
          _recordingComplete = true;
          _maybeSaveAndUploadAudio();
        }
      });
      _audioChunkSubscription ??= _bleService.audioChunks.listen((chunk) {
        _audioBytes.addAll(chunk);
        if (_expectedAudioBytes != null &&
            _audioBytes.length >= _expectedAudioBytes!) {
          _recordingComplete = true;
        }
        _maybeSaveAndUploadAudio();
      });

      await _bleService.connectToWearable();

      if (!mounted) return;

      setState(() {
        _wearableConnected = true;
        _wearableMessage = 'SalamaSphere connected. Ready for SOS.';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _wearableConnected = false;
        _wearableMessage = 'Connection failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _connectingWearable = false;
        });
      }
    }
  }

  // Receive an SOS event and submit it to Django.
  Future<void> _handleWearableEvent(WearableEvent event) async {
    if (!mounted) return;

    if (_processedEventIds.contains(event.eventId)) {
      return;
    }

    _processedEventIds.add(event.eventId);

    final location = await _locationService.captureLocation();
    final clientEventId = widget.apiService.clientEventIdFor(event.eventId);
    _activeEventClientId = clientEventId;
    _audioBytes.clear();
    _audioTransferMetadata = null;
    _expectedAudioBytes = null;
    _recordingComplete = false;

    await _localDatabase.saveIncident(
      clientEventId: clientEventId,
      deviceIdentifier: event.deviceIdentifier,
      eventType: event.eventType,
      capturedAt: event.timestamp,
      threatLevel: 'high',
      description: 'Wearable SOS event: ${event.eventId}',
      latitude: location?.latitude,
      longitude: location?.longitude,
      locationAccuracy: location?.accuracy,
      locationCapturedAt: location?.capturedAt,
      locationSource: location == null ? 'unavailable' : 'phone_gps',
    );

    // Some firmware versions begin audio transfer automatically; newer
    // versions wait for this explicit command. Either path is supported.
    try {
      await _bleService.requestAudioTransfer(transferId: event.eventId);
    } catch (_) {
      // The SOS incident remains valid when this optional characteristic is
      // absent or the wearable has no recording for the event.
    }

    setState(() {
      _submittingSos = true;
      _wearableMessage = 'SOS received: ${event.eventId}. Saving incident...';
    });

    try {
      final token = widget.apiService.authToken;
      final synchronized =
          token != null &&
          await _incidentSync.synchronizePendingIncidents(token: token);
      if (token != null) {
        await _incidentSync.synchronizePendingAudio(
          upload: widget.apiService.uploadIncidentAudio,
        );
        await _notifySynchronizedIncidents();
      }
      final result = <String, dynamic>{
        'success': synchronized,
        'message': token == null
            ? 'SOS saved locally and is waiting for login.'
            : 'Upload is pending until the backend is reachable.',
      };

      if (!mounted) return;

      if (result['success'] == true) {
        setState(() {
          _wearableMessage = 'SOS incident saved successfully.';
        });

        // Reload the incident history from Django.
        await _loadIncidents();

        if (!mounted) return;

        setState(() {
          _wearableMessage = 'SOS processed. Check your incident history.';
        });
      } else {
        // Permit a later retry if submission failed.
        _processedEventIds.remove(event.eventId);

        setState(() {
          _wearableMessage =
              'SOS saved locally; upload is pending. '
              '${result['message'] ?? 'Reconnect to retry.'}';
        });
      }
    } catch (error) {
      _processedEventIds.remove(event.eventId);

      if (!mounted) return;

      setState(() {
        _wearableMessage = 'SOS submission error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _submittingSos = false;
        });
      }
    }
  }

  void _handleRecordingStatus(String status) {
    if (!mounted) return;
    setState(() {
      _wearableMessage = 'Recording transfer: $status';
    });

    if (status.toLowerCase() == 'complete') {
      _recordingComplete = true;
      _maybeSaveAndUploadAudio();
    }
  }

  void _maybeSaveAndUploadAudio() {
    if (_recordingComplete &&
        _activeEventClientId != null &&
        _audioBytes.isNotEmpty) {
      _saveAndUploadAudio(_activeEventClientId!);
    }
  }

  Future<void> _saveAndUploadAudio(String clientEventId) async {
    if (_audioSaveInProgress) return;
    _audioSaveInProgress = true;
    final metadata = _audioTransferMetadata ?? const <String, dynamic>{};
    try {
      await _localDatabase.saveIncidentAudio(
        clientEventId: clientEventId,
        bytes: List<int>.from(_audioBytes),
        fileName: metadata['file_name']?.toString() ?? 'sos-audio.bin',
        mimeType:
            metadata['mime_type']?.toString() ?? 'application/octet-stream',
      );

      // Audio can arrive after the incident has already synchronized. Attach it
      // explicitly so it becomes eligible for upload in either arrival order.
      final incident = await _localDatabase.getIncident(clientEventId);
      final serverIncidentId = incident?['server_incident_id']?.toString();
      if (serverIncidentId != null && serverIncidentId.isNotEmpty) {
        await _localDatabase.attachAudioToServerIncident(
          clientEventId: clientEventId,
          serverIncidentId: serverIncidentId,
        );
      }

      if (widget.apiService.authToken != null) {
        await _incidentSync.synchronizePendingIncidents(
          token: widget.apiService.authToken!,
        );
        await _incidentSync.synchronizePendingAudio(
          upload: widget.apiService.uploadIncidentAudio,
        );
      }
      if (mounted) await _loadIncidents();
    } finally {
      _audioSaveInProgress = false;
    }
  }

  Future<void> _manageTrustedContacts() async {
    try {
      final contacts = await _notifications.getTrustedContacts();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Trusted contacts'),
          content: SizedBox(
            width: double.maxFinite,
            child: contacts.isEmpty
                ? const Text('No contacts configured yet.')
                : ListView(
                    shrinkWrap: true,
                    children: contacts
                        .map(
                          (contact) => ListTile(
                            leading: const Icon(Icons.person),
                            title: Text(contact.name),
                            subtitle: Text(
                              '${contact.phoneNumber}\n'
                              '${contact.smsEnabled ? 'SMS alerts enabled' : 'SMS alerts disabled'}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                await _addTrustedContact();
              },
              child: const Text('Add contact'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _showMessage('Could not load trusted contacts: $error');
    }
  }

  Future<void> _addTrustedContact() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final emailController = TextEditingController();
    var smsEnabled = true;
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add trusted contact'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a name'
                      : null,
                ),
                TextFormField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Kenyan phone number',
                    hintText: '+254 7XX XXX XXX',
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a phone number'
                      : null,
                ),
                TextFormField(
                  controller: emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email (optional)',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Receive SMS alerts'),
                  value: smsEnabled,
                  onChanged: (value) =>
                      setDialogState(() => smsEnabled = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (!(formKey.currentState?.validate() ?? false)) return;
                final result = await _notifications.saveTrustedContact(
                  TrustedContact(
                    name: nameController.text,
                    phoneNumber: phoneController.text,
                    email: emailController.text,
                    smsEnabled: smsEnabled,
                  ),
                );
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext, result['success'] == true);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    phoneController.dispose();
    emailController.dispose();
    if (saved == true && mounted) _showMessage('Trusted contact saved.');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _field(
    Map<String, dynamic> incident,
    List<String> keys, {
    String fallback = 'Not provided',
  }) {
    for (final key in keys) {
      final value = incident[key];

      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }

    return fallback;
  }

  String _formatDate(String raw) {
    final date = DateTime.tryParse(raw)?.toLocal();

    if (date == null) return raw;

    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');

    return '$day/$month/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  void _logout() {
    widget.apiService.logout();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(
        builder: (_) => LoginScreen(apiService: widget.apiService),
      ),
      (route) => false,
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF087F8C)),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _featureCard({
    required IconData icon,
    required String title,
    required String description,
    VoidCallback? onTap,
  }) {
    return Card(
      elevation: 0,
      color: const Color(0xFFF2F8F8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28, color: const Color(0xFF087F8C)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Wearable connection card.
  Widget _wearableCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _wearableConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth,
                  color: const Color(0xFF087F8C),
                  size: 30,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'SalamaSphere Wearable',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                if (_wearableConnected)
                  const Icon(Icons.check_circle, color: Colors.green),
              ],
            ),
            const SizedBox(height: 12),
            Text(_wearableMessage),
            if (_submittingSos) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _connectingWearable || _wearableConnected
                    ? null
                    : _connectWearable,
                icon: Icon(
                  _connectingWearable
                      ? Icons.hourglass_top
                      : Icons.bluetooth_searching,
                ),
                label: Text(
                  _connectingWearable
                      ? 'Connecting...'
                      : _wearableConnected
                      ? 'Wearable Connected'
                      : 'Connect Wearable',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF087F8C),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _incidentCard(dynamic item) {
    if (item is! Map) {
      return const SizedBox.shrink();
    }

    final incident = Map<String, dynamic>.from(item);

    final id = _field(incident, [
      'id',
      'incident_id',
      'uuid',
    ], fallback: 'ID unavailable');

    final type = _field(incident, [
      'incident_type_display',
      'incident_type',
      'event_type',
      'type',
      'source',
    ], fallback: 'Incident');

    final threat = _field(incident, [
      'threat_level_display',
      'threat_level',
      'severity',
    ], fallback: 'Not assessed');

    final status = _field(incident, [
      'status_display',
      'status',
      'sync_status',
    ], fallback: 'Recorded');

    final date = _field(incident, [
      'created_at',
      'timestamp',
      'occurred_at',
      'captured_at',
      'created',
    ], fallback: '');

    final clientEventId = _field(incident, [
      'client_event_id',
      'wearable_event_id',
      'event_id',
    ], fallback: '');
    final audioUrl = _field(incident, [
      'audio_url',
      'audio_file_url',
      'recording_url',
    ], fallback: '');
    final localAudio = _localAudioByEventId[clientEventId];
    final hasAudio = audioUrl.isNotEmpty || localAudio != null;
    final location = _locationText(incident);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFE0F2F1),
                  child: Icon(Icons.shield_outlined, color: Color(0xFF087F8C)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        type,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Incident ID: $id',
                        style: const TextStyle(
                          color: Colors.black54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Text('Threat level: $threat'),
            const SizedBox(height: 6),
            Text('Status: $status'),
            if (date.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Date: ${_formatDate(date)}'),
            ],
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 18,
                  color: Color(0xFF087F8C),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(location)),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  hasAudio ? Icons.audiotrack : Icons.audio_file_outlined,
                  size: 18,
                  color: hasAudio ? const Color(0xFF087F8C) : Colors.black38,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    hasAudio
                        ? 'Wearable audio attached${localAudio?['upload_status'] == 'uploaded' ? ' and uploaded' : ''}.'
                        : 'No wearable audio attached.',
                    style: TextStyle(
                      color: hasAudio
                          ? const Color(0xFF087F8C)
                          : Colors.black54,
                    ),
                  ),
                ),
              ],
            ),
            if (hasAudio)
              TextButton.icon(
                onPressed: () => _showAudioAccess(incident, localAudio),
                icon: const Icon(Icons.lock_open_outlined),
                label: const Text('Access recording securely'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAudioAccess(
    Map<String, dynamic> incident,
    Map<String, Object?>? localAudio,
  ) async {
    final incidentId = _field(incident, [
      'id',
      'incident_id',
      'uuid',
    ], fallback: '');
    final clientEventId = _field(incident, [
      'client_event_id',
      'wearable_event_id',
      'event_id',
    ], fallback: '');
    List<int>? bytes;
    String? error;

    if (localAudio != null && clientEventId.isNotEmpty) {
      bytes = await _localDatabase.getIncidentAudioBytes(clientEventId);
    }
    if (bytes == null && incidentId.isNotEmpty) {
      final response = await widget.apiService.fetchIncidentAudio(incidentId);
      if (response['success'] == true) {
        bytes = List<int>.from(response['bytes'] as List);
      } else {
        error = response['message']?.toString();
      }
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Incident recording'),
        content: Text(
          error ??
              (bytes == null
                  ? 'No audio bytes are available for this incident yet.'
                  : 'The recording is ready to play securely in this dashboard.'),
        ),
        actions: [
          if (bytes != null)
            TextButton.icon(
              onPressed: () async {
                await _audioPlayer.stop();
                await _audioPlayer.play(
                  BytesSource(Uint8List.fromList(bytes!)),
                );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play'),
            ),
          if (bytes != null)
            TextButton.icon(
              onPressed: () async => _audioPlayer.stop(),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _locationText(Map<String, dynamic> incident) {
    final nested = incident['location'];
    final source = nested is Map ? nested : incident;
    final latitude = source['latitude'] ?? incident['latitude'];
    final longitude = source['longitude'] ?? incident['longitude'];
    if (latitude == null || longitude == null) {
      return 'Location unavailable';
    }
    final accuracy =
        source['accuracy_m'] ??
        source['location_accuracy_m'] ??
        incident['location_accuracy_m'] ??
        incident['location_accuracy'];
    final accuracyText = accuracy == null
        ? ''
        : ' (+/- ${double.tryParse(accuracy.toString())?.toStringAsFixed(0) ?? accuracy} m)';
    return '${double.tryParse(latitude.toString())?.toStringAsFixed(6) ?? latitude}, '
        '${double.tryParse(longitude.toString())?.toStringAsFixed(6) ?? longitude}$accuracyText';
  }

  @override
  void dispose() {
    _wearableSubscription?.cancel();
    _recordingStatusSubscription?.cancel();
    _audioMetadataSubscription?.cancel();
    _audioChunkSubscription?.cancel();
    _audioPlayer.dispose();
    _connectivitySubscription?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: AppBar(
        title: const Text('SalamaSphere'),
        backgroundColor: const Color(0xFF087F8C),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh incidents',
            onPressed: _loading ? null : _loadIncidents,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Log out',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadIncidents,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF087F8C),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.health_and_safety_outlined,
                    color: Colors.white,
                    size: 34,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Welcome, ${widget.username}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your safety space. Access your incident history '
                    'and monitor your connection.',
                    style: TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        _connected ? Icons.cloud_done : Icons.cloud_off,
                        color: Colors.white,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _connected
                              ? 'Backend connected'
                              : 'Backend unavailable',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            _sectionTitle('Wearable connection', Icons.bluetooth),
            _wearableCard(),

            const SizedBox(height: 24),

            _sectionTitle('Your incident history', Icons.history),
            Text(_message),
            const SizedBox(height: 12),

            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (!_connected)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.cloud_off,
                        size: 36,
                        color: Colors.orange,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your incident history could not be loaded.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _loadIncidents,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              )
            else if (_incidents.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(
                        Icons.inbox_outlined,
                        size: 44,
                        color: Colors.black45,
                      ),
                      SizedBox(height: 10),
                      Text(
                        'No incidents recorded yet',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Incidents will appear here when they have '
                        'been created and linked to your account.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              ..._incidents.map(_incidentCard),

            const SizedBox(height: 24),

            _sectionTitle('Safety tools', Icons.security),

            _featureCard(
              icon: Icons.watch_outlined,
              title: 'Wearable device',
              description: 'Connect your wearable to receive SOS events.',
            ),

            _featureCard(
              icon: Icons.folder_outlined,
              title: 'Evidence vault',
              description:
                  'Evidence upload and integrity verification '
                  'will connect to the backend evidence API.',
            ),

            _featureCard(
              icon: Icons.people_outline,
              title: 'Trusted contacts',
              description:
                  'Choose who receives privacy-conscious SOS SMS alerts.',
              onTap: _manageTrustedContacts,
            ),

            const SizedBox(height: 12),

            const Text(
              'For immediate danger, contact local emergency '
              'services or a trusted person. This development '
              'version does not yet guarantee SOS delivery.',
              style: TextStyle(color: Colors.black54, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

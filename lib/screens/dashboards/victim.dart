import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/wearable_event.dart';
import '../../services/api_service.dart';
import '../../services/ble_service.dart';
import '../../services/incident_sync_service.dart';
import '../../services/local_database_service.dart';
import '../../services/location_service.dart';
import '../../services/notification_service.dart';
import '../../models/trusted_contact.dart';
import '../../widgets/incident_media.dart';
import '../login_screen.dart';

// ---------------------------------------------------------------------------
// Shared look & feel
// ---------------------------------------------------------------------------
const Color _brand = Color(0xFF087F8C);
const Color _brandDark = Color(0xFF056470);
const Color _brandSoft = Color(0xFFE3F3F4);
const Color _pageBg = Color(0xFFF4F8F9);

// Tab indexes (bottom navigation).
const int _tabHome = 0;
const int _tabIncidents = 1;
const int _tabEvidence = 2;
const int _tabAlerts = 3;
const int _tabContacts = 4;

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
  int _selectedTab = _tabHome;
  bool _loadingNotifications = false;
  List<dynamic> _notificationsList = [];
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
  StreamSubscription<bool>? _bleConnectionSubscription;
  StreamSubscription<Object>? _bleErrorSubscription;

  bool _connectingWearable = false;
  bool _wearableConnected = false;
  bool _submittingSos = false;

  String _wearableMessage = 'Wearable not connected';
  Map<String, dynamic>? _audioTransferMetadata;
  int? _expectedAudioBytes;
  final List<int> _audioBytes = <int>[];
  bool _recordingComplete = false;
  bool _audioSaveInProgress = false;
  String? _activeWearableEventId;
  final Set<String> _requestedAudioEventIds = <String>{};
  final Map<String, WearableEvent> _wearableEventsById =
      <String, WearableEvent>{};

  // Prevent the same event notification from being processed
  // more than once during this screen session.
  final Set<String> _processedEventIds = <String>{};
  final Set<String> _sessionNotificationKeys = <String>{};

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

  Future<void> playWav(List<int> bytes) async {
    await _audioPlayer.play(BytesSource(Uint8List.fromList(bytes)));
  }

  // =========================================================================
  // LOGIC (unchanged)
  // =========================================================================

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
    await _deleteUploadedWearableRecordings();
    if (mounted) await _loadIncidents();
  }

  Future<void> _deleteUploadedWearableRecordings() async {
    if (!_bleService.isConnected) return;
    for (final incident in await _localDatabase.getAllIncidents()) {
      final clientEventId = incident['client_event_id']?.toString();
      final description = incident['description']?.toString() ?? '';
      if (clientEventId == null ||
          !description.startsWith('Wearable SOS event: ')) {
        continue;
      }
      final audio = await _localDatabase.getIncidentAudio(clientEventId);
      if (audio?['upload_status'] != 'uploaded') continue;
      final transferId = description.substring('Wearable SOS event: '.length);
      try {
        await _bleService.acknowledgeAudioTransfer(transferId: transferId);
      } catch (_) {
        // The SD-card copy remains available for a later reconnect.
      }
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
      final response = await widget.apiService.fetchDashboardOverview();

      if (!mounted) return;

      final dynamic data = response['data'];
      final List<dynamic> retrieved = [];

      if (data is Map && data['incidents'] is List) {
        retrieved.addAll(data['incidents'] as List);
      }

      // Keep local metadata and encrypted audio reachable even when the
      // backend does not echo the wearable/client event identifiers.
      final localIncidents = await _localDatabase.getAllIncidents();
      _localAudioByEventId.clear();
      for (final incident in localIncidents) {
        final clientId = incident['client_event_id']?.toString();
        if (clientId == null) continue;
        final audio = await _localDatabase.getIncidentAudio(clientId);
        if (audio != null) _localAudioByEventId[clientId] = audio;
      }

      for (final localIncident in localIncidents) {
        final clientEventId =
            localIncident['client_event_id']?.toString() ?? '';
        if (clientEventId.isEmpty) continue;
        final description = localIncident['description']?.toString() ?? '';
        final wearableEventId = description.startsWith('Wearable SOS event: ')
            ? description.substring('Wearable SOS event: '.length)
            : '';
        final serverIncidentId =
            localIncident['server_incident_id']?.toString() ?? '';
        final matchingIndex = retrieved.indexWhere((item) {
          if (item is! Map) return false;
          final remote = Map<String, dynamic>.from(item);
          final remoteIds = [
            remote['id'],
            remote['incident_id'],
            remote['uuid'],
            remote['client_event_id'],
            remote['wearable_event_id'],
            remote['event_id'],
          ].map((value) => value?.toString()).whereType<String>();
          return remoteIds.contains(clientEventId) ||
              (wearableEventId.isNotEmpty &&
                  remoteIds.contains(wearableEventId)) ||
              (serverIncidentId.isNotEmpty &&
                  remoteIds.contains(serverIncidentId));
        });
        final incidentId = serverIncidentId.isNotEmpty
            ? serverIncidentId
            : clientEventId;
        if (matchingIndex < 0) {
          retrieved.add({
            ...localIncident,
            'id': incidentId,
            'client_event_id': clientEventId,
          });
        } else {
          final remote = Map<String, dynamic>.from(
            retrieved[matchingIndex] as Map,
          );
          retrieved[matchingIndex] = {
            ...remote,
            ...localIncident,
            'id': remote['id'] ?? incidentId,
            'client_event_id': clientEventId,
          };
        }
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
        final expected = _expectedAudioBytes;

        // Ignore bytes once the advertised file length has arrived.
        if (expected != null &&
            (_audioBytes.length >= expected ||
                _audioBytes.length + chunk.length > expected)) {
          if (mounted) {
            setState(() {
              _wearableMessage = 'Audio transfer size mismatch. Please retry.';
            });
          }
          return;
        }

        _audioBytes.addAll(chunk);

        if (expected != null &&
            expected > 0 &&
            _audioBytes.length == expected &&
            _audioTransferMetadata != null) {
          _recordingComplete = true;
        }

        _maybeSaveAndUploadAudio();
      });
      _bleConnectionSubscription ??=
          Stream<bool>.periodic(
            const Duration(seconds: 1),
            (_) => _bleService.isConnected,
          ).distinct().listen((connected) {
            if (!mounted) return;
            setState(() {
              _wearableConnected = connected;
              _wearableMessage = connected
                  ? 'Wearable connected. Waiting for SOS events.'
                  : 'Wearable disconnected. Reconnect to resume monitoring.';
            });
            if (connected) {
              _addSessionNotification(
                key: 'wearable-connected',
                title: 'Wearable connected',
                message: 'Your SalamaSphere wearable is connected to the app.',
              );
            }
            if (!connected) _requestedAudioEventIds.clear();
          });
      _bleErrorSubscription ??= _bleService.errors.listen((error) {
        _requestedAudioEventIds.remove(_activeWearableEventId);
        if (!mounted) return;
        setState(() {
          _wearableMessage = 'Wearable communication error: $error';
        });
      });

      await _bleService.connectToWearable();
      if (!mounted) return;
      setState(() {
        _wearableConnected = true;
        _connectingWearable = false;
        _wearableMessage = 'Wearable connected. Waiting for SOS events.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _wearableMessage = 'Wearable connection error: $error';
        _connectingWearable = false;
      });
    }
  }

  // Receive an SOS event and submit it to Django.
  Future<void> _handleWearableEvent(WearableEvent event) async {
    if (!mounted) return;
    _wearableEventsById[event.eventId] = event;

    final existing = await _localDatabase.findIncidentByWearableEventId(
      event.eventId,
    );
    if (_processedEventIds.contains(event.eventId) || existing != null) {
      _processedEventIds.add(event.eventId);
      _wearableEventsById.remove(event.eventId);
      final clientEventId = existing?['client_event_id']?.toString();
      if (clientEventId != null) {
        _activeWearableEventId = event.eventId;
        final audio = await _localDatabase.getIncidentAudio(clientEventId);
        if (audio?['upload_status'] == 'uploaded') {
          try {
            await _bleService.acknowledgeAudioTransfer(
              transferId: event.eventId,
            );
          } catch (_) {
            // The recording will be offered again by the wearable on reconnect.
          }
        } else if (audio == null &&
            (event.recordingStatus == 'SAVED' ||
                event.recordingStatus == 'SAVED_PARTIAL')) {
          await _requestAudioForEvent(event.eventId);
        }
      }
      return;
    }

    _processedEventIds.add(event.eventId);
    final clientEventId = widget.apiService.clientEventIdFor(event.eventId);
    _activeWearableEventId = event.eventId;
    _audioBytes.clear();
    _audioTransferMetadata = null;
    _expectedAudioBytes = null;
    _recordingComplete = false;

    final location = await _locationService.captureLocation();
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
    _wearableEventsById.remove(event.eventId);

    if (event.callRequested) {
      unawaited(_offerTrustedContactCall());
    }
    if (event.recordingStatus == 'SAVED' ||
        event.recordingStatus == 'SAVED_PARTIAL') {
      await _requestAudioForEvent(event.eventId);
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
      }
      Map<String, dynamic>? savedIncident;
      for (final incident in await _localDatabase.getAllIncidents()) {
        if (incident['client_event_id'] == clientEventId) {
          savedIncident = incident;
          break;
        }
      }
      final syncError = savedIncident?['last_sync_error']?.toString();
      final result = <String, dynamic>{
        'success': synchronized,
        'message': token == null
            ? 'SOS saved locally and is waiting for login.'
            : syncError == null || syncError.isEmpty
            ? 'Upload is pending until the backend is reachable.'
            : 'Upload failed: $syncError',
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

  Future<void> _requestAudioForEvent(String eventId) async {
    if (!_requestedAudioEventIds.add(eventId)) return;
    try {
      await _bleService.requestAudioTransfer(transferId: eventId);
    } catch (_) {
      _requestedAudioEventIds.remove(eventId);
    }
  }

  Future<void> _offerTrustedContactCall() async {
    try {
      final contacts = (await _notifications.getTrustedContacts())
          .where(
            (contact) =>
                contact.active && contact.phoneNumber.trim().isNotEmpty,
          )
          .toList();
      if (!mounted) return;
      if (contacts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Add a trusted contact with a phone number to call.'),
          ),
        );
        return;
      }

      final selected = await showDialog<TrustedContact>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('SOS call requested'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: contacts
                  .map(
                    (contact) => ListTile(
                      leading: const Icon(Icons.call_outlined),
                      title: Text(contact.name),
                      subtitle: Text(contact.phoneNumber),
                      onTap: () => Navigator.pop(dialogContext, contact),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Not now'),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      final launched = await launchUrl(
        Uri(scheme: 'tel', path: selected.phoneNumber.trim()),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open the phone dialer.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start the SOS call flow: $error')),
      );
    }
  }

  void _handleRecordingStatus(String status) {
    if (!mounted) return;

    setState(() {
      _wearableMessage = 'Recording transfer: $status';
    });

    if ((status == 'SAVED' || status == 'SAVED_PARTIAL') &&
        _activeWearableEventId != null) {
      unawaited(_requestAudioForEvent(_activeWearableEventId!));
    }
  }

  void _maybeSaveAndUploadAudio() {
    final expected = _expectedAudioBytes;
    final transferId = _audioTransferMetadata?['transfer_id']?.toString();

    if (!_recordingComplete ||
        transferId == null ||
        transferId.isEmpty ||
        _audioTransferMetadata == null ||
        expected == null ||
        expected <= 0 ||
        _audioBytes.length != expected ||
        _audioSaveInProgress) {
      return;
    }

    unawaited(_saveAndUploadAudio(transferId));
  }

  Future<String> _ensureIncidentForAudioTransfer(String transferId) async {
    final existing = await _localDatabase.findIncidentByWearableEventId(
      transferId,
    );
    if (existing != null) {
      _wearableEventsById.remove(transferId);
      return existing['client_event_id']?.toString() ??
          widget.apiService.clientEventIdFor(transferId);
    }

    final location = await _locationService.captureLocation();
    final afterLocation = await _localDatabase.findIncidentByWearableEventId(
      transferId,
    );
    if (afterLocation != null) {
      _wearableEventsById.remove(transferId);
      return afterLocation['client_event_id']?.toString() ??
          widget.apiService.clientEventIdFor(transferId);
    }

    final clientEventId = widget.apiService.clientEventIdFor(transferId);
    final event = _wearableEventsById[transferId];
    final deviceIdentifier = _bleService.deviceIdentifier;
    await _localDatabase.saveIncident(
      clientEventId: clientEventId,
      deviceIdentifier:
          event?.deviceIdentifier ??
          (deviceIdentifier.isEmpty
              ? 'SalamaSphere wearable'
              : deviceIdentifier),
      eventType: event?.eventType ?? 'SOS',
      capturedAt: event?.timestamp ?? DateTime.now().toUtc(),
      threatLevel: 'high',
      description: 'Wearable SOS event: $transferId',
      latitude: location?.latitude,
      longitude: location?.longitude,
      locationAccuracy: location?.accuracy,
      locationCapturedAt: location?.capturedAt,
      locationSource: location == null ? 'unavailable' : 'phone_gps',
    );
    _wearableEventsById.remove(transferId);
    return clientEventId;
  }

  Future<void> _saveAndUploadAudio(String transferId) async {
    if (_audioSaveInProgress) return;
    _audioSaveInProgress = true;
    final metadata = _audioTransferMetadata ?? const <String, dynamic>{};
    try {
      final clientEventId = await _ensureIncidentForAudioTransfer(transferId);
      _activeWearableEventId = transferId;
      await _localDatabase.saveIncidentAudio(
        clientEventId: clientEventId,
        bytes: List<int>.from(_audioBytes),
        fileName: metadata['filename']?.toString() ?? 'sos-audio.wav',
        mimeType: metadata['mime_type']?.toString() ?? 'audio/wav',
      );
      _addSessionNotification(
        key: 'wearable-audio-$clientEventId',
        title: 'Wearable audio received',
        message: 'Audio from your wearable was transferred to this app.',
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
      final audio = await _localDatabase.getIncidentAudio(clientEventId);
      if (audio?['upload_status'] == 'uploaded' && transferId.isNotEmpty) {
        await _bleService.acknowledgeAudioTransfer(transferId: transferId);
      }
      if (mounted) await _loadIncidents();
    } catch (error) {
      if (mounted) {
        setState(() {
          _wearableMessage = 'Could not save transferred audio: $error';
        });
      }
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(Icons.people_alt_rounded, color: _brand),
              SizedBox(width: 10),
              Text('Trusted contacts'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: contacts.isEmpty
                ? const Text(
                    'No contacts configured yet. Add someone you trust to '
                    'receive your SOS alerts.',
                  )
                : ListView(
                    shrinkWrap: true,
                    children: contacts
                        .map(
                          (contact) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const CircleAvatar(
                              backgroundColor: _brandSoft,
                              child: Icon(Icons.person, color: _brand),
                            ),
                            title: Text(contact.name),
                            subtitle: Text(
                              '${contact.phoneNumber}\n'
                              '${contact.smsEnabled ? 'SMS alerts enabled' : 'SMS alerts disabled'}; '
                              '${contact.receiveVoiceCalls ? 'voice calls enabled' : 'voice calls disabled'}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Delete ${contact.name}',
                              onPressed: contact.id == null
                                  ? null
                                  : () async {
                                      final confirmed = await showDialog<bool>(
                                        context: dialogContext,
                                        builder: (confirmContext) =>
                                            AlertDialog(
                                              title: const Text(
                                                'Delete trusted contact?',
                                              ),
                                              content: Text(
                                                'Remove ${contact.name} '
                                                'from your trusted contacts?',
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                        confirmContext,
                                                        false,
                                                      ),
                                                  child: const Text('Cancel'),
                                                ),
                                                FilledButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                        confirmContext,
                                                        true,
                                                      ),
                                                  child: const Text('Delete'),
                                                ),
                                              ],
                                            ),
                                      );
                                      if (confirmed != true) return;
                                      final result = await _notifications
                                          .removeTrustedContact(contact.id!);
                                      if (!dialogContext.mounted) return;
                                      if (result['success'] == true) {
                                        Navigator.pop(dialogContext);
                                        _showMessage(
                                          'Trusted contact deleted.',
                                        );
                                        await _manageTrustedContacts();
                                      } else {
                                        _showMessage(
                                          result['message']?.toString() ?? 'Could not delete trusted contact.',
                                        );
                                      }
                                    },
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
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
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _brand),
              onPressed: () async {
                Navigator.pop(dialogContext);
                await _addTrustedContact();
              },
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add contact'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _showMessage('Could not load trusted contacts: $error');
    }
  }

  Future<void> _loadNotifications() async {
    setState(() => _loadingNotifications = true);
    final response = await widget.apiService.fetchNotifications();
    if (!mounted) return;
    final data = response['data'];
    setState(() {
      _loadingNotifications = false;
      _notificationsList = data is List
          ? data
          : data is Map && data['results'] is List
          ? data['results'] as List
          : [];
    });
  }

  Future<void> _openEvidenceComposer() async {
    List<TrustedContact> trustedContacts;
    try {
      trustedContacts = await _notifications.getTrustedContacts();
    } catch (error) {
      if (mounted) {
        _showMessage('Could not load trusted contacts: $error');
      }
      return;
    }
    if (!mounted) return;

    final messageController = TextEditingController();
    String shareWith = 'authorities';
    final selectedContactIds = <int>{};
    PlatformFile? selectedFile;
    final formKey = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(Icons.lock_outline_rounded, color: _brand),
              SizedBox(width: 10),
              Text('Share evidence'),
            ],
          ),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: messageController,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      hintText: 'Describe what happened...',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Enter a message'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: shareWith,
                    decoration: const InputDecoration(
                      labelText: 'Share with',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'authorities',
                        child: Text('Authorities'),
                      ),
                      DropdownMenuItem(
                        value: 'trusted_contacts',
                        child: Text('Trusted contacts'),
                      ),
                      DropdownMenuItem(
                        value: 'both',
                        child: Text('Authorities and trusted contacts'),
                      ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      shareWith = value ?? 'authorities';
                      if (shareWith == 'authorities') {
                        selectedContactIds.clear();
                      }
                    }),
                  ),
                  if (shareWith != 'authorities') ...[
                    const SizedBox(height: 8),
                    if (trustedContacts.isEmpty)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Add a trusted contact before sharing with contacts.',
                        ),
                      )
                    else
                      ...trustedContacts.map((contact) {
                        final id = int.tryParse(contact.id ?? '');
                        if (id == null) return const SizedBox.shrink();
                        return CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: selectedContactIds.contains(id),
                          title: Text(contact.name),
                          subtitle: Text(contact.phoneNumber),
                          onChanged: (selected) => setDialogState(() {
                            if (selected == true) {
                              selectedContactIds.add(id);
                            } else {
                              selectedContactIds.remove(id);
                            }
                          }),
                        );
                      }),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          final files = await FilePicker.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: const [
                              'aac',
                              'amr',
                              'mp3',
                              'm4a',
                              'wav',
                              'mp4',
                              'mov',
                              'webm',
                            ],
                          );
                          if (files.isEmpty) return;
                          final file = files.first;
                          setDialogState(() {
                            selectedFile = file;
                          });
                        } catch (error) {
                          if (mounted) {
                            _showMessage('Could not select evidence: $error');
                          }
                        }
                      },
                      icon: Icon(
                        selectedFile == null
                            ? Icons.attach_file
                            : Icons.check_circle,
                        color: selectedFile == null ? null : Colors.green,
                      ),
                      label: Text(
                        selectedFile == null
                            ? 'Choose audio or video'
                            : selectedFile!.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (selectedFile == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Select an audio or video file.',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _brand),
              onPressed: () async {
                if (!(formKey.currentState?.validate() ?? false) ||
                    selectedFile == null) {
                  _showMessage('Choose a file and enter a message.');
                  return;
                }
                if (shareWith != 'authorities' && selectedContactIds.isEmpty) {
                  _showMessage('Select at least one trusted contact.');
                  return;
                }
                final file = selectedFile!;
                int? fileLength;
                try {
                  fileLength = await file.length();
                } catch (error) {
                  if (mounted) {
                    _showMessage(
                      'Could not read the selected evidence file: $error',
                    );
                  }
                  return;
                }
                if (!mounted || !dialogContext.mounted) return;
                if (fileLength == null || fileLength <= 0) {
                  _showMessage('Could not read the selected evidence file.');
                  return;
                }
                // Capture the text before the dialog closes, because the
                // controller is disposed once the dialog future completes.
                final messageText = messageController.text;
                final selectedContacts = trustedContacts
                    .where(
                      (contact) => selectedContactIds.contains(
                        int.tryParse(contact.id ?? ''),
                      ),
                    )
                    .toList();
                final selectedShareWith = shareWith;
                Navigator.pop(dialogContext);
                _showMessage('Getting your location...');
                final location = await _locationService.captureLocation();
                if (!mounted) return;
                _showMessage(
                  location == null
                      ? 'Location unavailable. Uploading without coordinates.'
                      : 'Uploading incident with your current location...',
                );
                final incident = await widget.apiService.createUserIncident(
                  description: messageText,
                  shareWith: selectedShareWith,
                  latitude: location?.latitude,
                  longitude: location?.longitude,
                  locationAccuracy: location?.accuracy,
                  locationSource: location == null ? null : 'mobile_gps',
                );
                final data = incident['data'];
                final incidentId = data is Map
                    ? (data['id'] ?? data['incident_id'] ?? data['uuid'])
                          ?.toString()
                    : null;
                if (incident['success'] != true || incidentId == null) {
                  _showMessage(
                    incident['message']?.toString() ??
                        'Could not create incident.',
                  );
                  return;
                }
                final upload = await widget.apiService.uploadEvidenceVault(
                  incidentId: incidentId,
                  fileStream: file.readAsByteStream(),
                  fileLength: fileLength,
                  fileName: file.name,
                  mimeType: _mimeTypeForFile(file.extension),
                  shareWith: selectedShareWith,
                  trustedContactIds: selectedContactIds.toList(),
                  message: messageText,
                );
                if (mounted) {
                  _showMessage(
                    upload['message']?.toString() ?? 'Evidence submitted.',
                  );
                  await _loadIncidents();
                  if (upload['success'] == true &&
                      selectedContacts.isNotEmpty) {
                    await _shareEvidenceBytes(
                      fileName: file.name,
                      mimeType: _mimeTypeForFile(file.extension),
                      bytes: await file.readAsBytes(),
                      contacts: selectedContacts,
                    );
                  }
                }
              },
              icon: const Icon(Icons.shield_outlined),
              label: const Text('Share securely'),
            ),
          ],
        ),
      ),
    );
    messageController.dispose();
  }

  Future<void> _addTrustedContact() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    var smsEnabled = true;
    var consentConfirmed = false;
    var voiceCallsEnabled = false;
    var voiceConsentConfirmed = false;
    var saving = false;
    String? saveError;
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(Icons.person_add_alt_1, color: _brand),
              SizedBox(width: 10),
              Text('Add trusted contact'),
            ],
          ),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Enter a name'
                        : null,
                  ),
                  TextFormField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Kenyan phone number',
                      hintText: '0712 345 678 or +254 712 345 678',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Enter a phone number'
                        : null,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Receive SMS alerts'),
                    value: smsEnabled,
                    onChanged: (value) =>
                        setDialogState(() => smsEnabled = value),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      "I have this contact's permission to receive SOS alerts.",
                    ),
                    value: consentConfirmed,
                    onChanged: (value) =>
                        setDialogState(() => consentConfirmed = value ?? false),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Receive automated voice calls'),
                    value: voiceCallsEnabled,
                    onChanged: (value) =>
                        setDialogState(() => voiceCallsEnabled = value),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      "I have this contact's permission to receive "
                      'automated emergency voice calls.',
                    ),
                    value: voiceConsentConfirmed,
                    onChanged: (value) => setDialogState(
                      () => voiceConsentConfirmed = value ?? false,
                    ),
                  ),
                  if (saveError != null)
                    Text(
                      saveError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _brand),
              onPressed: saving
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;
                      if (smsEnabled && !consentConfirmed) {
                        setDialogState(
                          () => saveError = 'Confirm contact permission before enabling SOS SMS alerts.',
                        );
                        return;
                      }
                      if (voiceCallsEnabled && !voiceConsentConfirmed) {
                        setDialogState(
                          () => saveError = 'Confirm contact permission before enabling emergency voice calls.',
                        );
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        saveError = null;
                      });
                      final result = await _notifications.saveTrustedContact(
                        TrustedContact(
                          name: nameController.text,
                          phoneNumber: normalizeKenyanPhoneNumber(
                            phoneController.text,
                          ),
                          smsEnabled: smsEnabled,
                          consentConfirmed: consentConfirmed,
                          receiveVoiceCalls: voiceCallsEnabled,
                          confirmVoiceConsent: voiceConsentConfirmed,
                        ),
                      );
                      if (!dialogContext.mounted) return;
                      if (result['success'] == true) {
                        Navigator.pop(dialogContext, true);
                      } else {
                        setDialogState(() {
                          saving = false;
                          saveError =
                              result['message']?.toString() ??
                              'Could not save trusted contact.';
                        });
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    phoneController.dispose();
    if (saved == true && mounted) {
      _showMessage('Trusted contact saved.');
      await _manageTrustedContacts();
    } else if (saveError != null && mounted) {
      _showMessage(saveError!);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _addSessionNotification({
    required String key,
    required String title,
    required String message,
  }) {
    if (!mounted || !_sessionNotificationKeys.add(key)) return;
    setState(() {
      _notificationsList = [
        {
          'id': key,
          'title': title,
          'message': message,
          'is_read': false,
          'created_at': DateTime.now().toIso8601String(),
        },
        ..._notificationsList,
      ];
    });
    _showMessage(title);
  }

  String _mimeTypeForFile(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'amr':
        return 'audio/amr';
      case 'wav':
        return 'audio/wav';
      default:
        return 'application/octet-stream';
    }
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

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Log out?'),
        content: const Text(
          'You will need to sign in again to see your incidents.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed == true) _logout();
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.graphic_eq, color: _brand),
            SizedBox(width: 10),
            Text('Incident recording'),
          ],
        ),
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
          if (bytes != null)
            TextButton.icon(
              onPressed: () => _shareAudio(incidentId, bytes!),
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share audio'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showIncidentMedia(Map<String, dynamic> incident) async {
    final incidentId = _field(incident, [
      'id',
      'incident_id',
      'uuid',
    ], fallback: '');
    if (incidentId.isEmpty || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Incident media'),
        content: SingleChildScrollView(
          child: IncidentEvidenceList(
            apiService: widget.apiService,
            incidentId: incidentId,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openEvidenceFile(Map<String, dynamic> evidence) async {
    final evidenceId = evidence['id']?.toString();
    if (evidenceId == null || evidenceId.isEmpty) return;

    final response = await widget.apiService.fetchEvidenceFile(evidenceId);
    if (!mounted) return;
    if (response['success'] != true) {
      if (mounted) {
        _showMessage(
          response['message']?.toString() ?? 'Could not open evidence.',
        );
      }
      return;
    }

    final bytes = List<int>.from(response['bytes'] as List);
    final fileName = evidence['original_filename']?.toString() ?? 'evidence';
    final mimeType = resolveEvidenceMimeType(
      mimeType:
          response['mime_type']?.toString() ??
          evidence['mime_type']?.toString(),
      fileName: fileName,
    );

    if (mimeType.startsWith('video/')) {
      await showEvidenceMediaDialog(
        context,
        fileName: fileName,
        mimeType: mimeType,
        bytes: bytes,
      );
      return;
    }

    if (mimeType.startsWith('audio/')) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
          content: const Text('Audio evidence is ready to play.'),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await _audioPlayer.stop();
                await _audioPlayer.play(BytesSource(Uint8List.fromList(bytes)));
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play'),
            ),
            TextButton.icon(
              onPressed: () => _shareEvidenceBytes(
                fileName: fileName,
                mimeType: mimeType,
                bytes: bytes,
              ),
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    if (mounted) {
      _showMessage('This evidence format cannot be previewed in the app.');
    }
  }

  Future<void> _shareUploadedEvidence(Map<String, dynamic> evidence) async {
    List<TrustedContact> contacts;
    try {
      contacts = await _notifications.getTrustedContacts();
    } catch (error) {
      if (mounted) _showMessage('Could not load trusted contacts: $error');
      return;
    }
    if (!mounted) return;
    if (contacts.isEmpty) {
      if (mounted) _showMessage('Add a trusted contact before sharing files.');
      return;
    }

    final selected = <String>{};
    final recipients = await showDialog<List<TrustedContact>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Share with trusted contacts'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: contacts.map((contact) {
                final id = contact.id;
                if (id == null) return const SizedBox.shrink();
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: selected.contains(id),
                  title: Text(contact.name),
                  subtitle: Text(contact.phoneNumber),
                  onChanged: (value) => setDialogState(() {
                    if (value == true) {
                      selected.add(id);
                    } else {
                      selected.remove(id);
                    }
                  }),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      dialogContext,
                      contacts
                          .where((contact) => selected.contains(contact.id))
                          .toList(),
                    ),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    if (recipients == null || recipients.isEmpty) return;

    final result = await widget.apiService.fetchEvidenceFile(
      evidence['id'].toString(),
    );
    if (result['success'] != true) {
      if (mounted) {
        _showMessage(
          result['message']?.toString() ?? 'Could not download evidence.',
        );
      }
      return;
    }
    final fileName = evidence['original_filename']?.toString() ?? 'evidence';
    await _shareEvidenceBytes(
      fileName: fileName,
      mimeType: resolveEvidenceMimeType(
        mimeType: evidence['mime_type']?.toString(),
        fileName: fileName,
      ),
      bytes: List<int>.from(result['bytes'] as List),
      contacts: recipients,
    );
  }

  Future<void> _shareEvidenceBytes({
    required String fileName,
    required String mimeType,
    required List<int> bytes,
    List<TrustedContact> contacts = const [],
  }) async {
    final recipientText = contacts.isEmpty
        ? ''
        : '\nFor: ${contacts.map((contact) => '${contact.name} (${contact.phoneNumber})').join(', ')}';
    try {
      await const MethodChannel('com.salamasphere/share')
          .invokeMethod<void>('shareMedia', {
            'title': 'SalamaSphere evidence',
            'fileName': fileName,
            'mimeType': mimeType,
            'text': 'SalamaSphere shared evidence.$recipientText',
            'bytes': Uint8List.fromList(bytes),
          });
    } on PlatformException catch (error) {
      if (mounted) _showMessage('Could not share evidence: ${error.message}');
    } on MissingPluginException {
      if (mounted) _showMessage('File sharing is unavailable on this device.');
    }
  }

  Future<void> _shareAudio(String incidentId, List<int> bytes) async {
    try {
      await const MethodChannel('com.salamasphere/share')
          .invokeMethod<void>('shareMedia', {
            'title': 'SalamaSphere incident recording $incidentId',
            'fileName': 'salamasphere-$incidentId.wav',
            'mimeType': 'audio/wav',
            'bytes': Uint8List.fromList(bytes),
          });
    } on PlatformException catch (error) {
      if (mounted) _showMessage('Could not share recording: ${error.message}');
    } on MissingPluginException {
      if (mounted) _showMessage('File sharing is unavailable on this device.');
    }
  }

  Future<void> _shareIncident(Map<String, dynamic> incident) async {
    final id = _field(incident, [
      'id',
      'incident_id',
      'uuid',
    ], fallback: 'unknown');
    final clientEventId = _field(incident, [
      'client_event_id',
      'wearable_event_id',
      'event_id',
    ], fallback: '');
    final threat = _field(incident, [
      'threat_level',
      'threat',
    ], fallback: 'unknown');
    final occurred = _field(incident, [
      'occurred_at',
      'created_at',
    ], fallback: 'unknown');
    final nestedLocation = incident['location'];
    final locationSource = nestedLocation is Map ? nestedLocation : incident;
    final mapUri = googleMapsUriForCoordinates(
      locationSource['latitude'] ?? incident['latitude'],
      locationSource['longitude'] ?? incident['longitude'],
    );
    final location = mapUri?.toString() ?? 'Location unavailable';
    final description = _field(incident, ['description'], fallback: '');
    final text = StringBuffer(
      'SalamaSphere incident\n'
      'ID: $id\n'
      'Threat: $threat\n'
      'Time: $occurred\n'
      'Location: $location',
    );
    if (description.isNotEmpty) {
      text.write('\nDetails: $description');
    }

    dynamic evidenceItems = incident['evidence'];
    if (id != 'unknown' && id != clientEventId) {
      final response = await widget.apiService.fetchIncidentEvidence(id);
      if (response['success'] != true) {
        if (mounted) {
          _showMessage(
            response['message']?.toString() ??
                'Could not load incident media to share.',
          );
        }
        return;
      }
      final data = response['data'];
      evidenceItems = data is Map && data['results'] is List
          ? data['results']
          : data is Map && data['evidence'] is List
          ? data['evidence']
          : data;
    }
    while (evidenceItems is Map) {
      if (evidenceItems['results'] is List) {
        evidenceItems = evidenceItems['results'];
      } else if (evidenceItems['evidence'] is List) {
        evidenceItems = evidenceItems['evidence'];
      } else if (evidenceItems['data'] is List ||
          evidenceItems['data'] is Map) {
        evidenceItems = evidenceItems['data'];
      } else {
        break;
      }
    }

    final mediaFiles = <Map<String, Object>>[];
    var hasAudioEvidence = false;
    if (evidenceItems is List) {
      for (final item in evidenceItems) {
        if (item is! Map ||
            item['id'] == null ||
            item['original_filename'] == null) {
          if (mounted) {
            _showMessage(
              'Incident media details are incomplete; nothing shared.',
            );
          }
          return;
        }
        final evidence = Map<String, dynamic>.from(item);
        final evidenceId = evidence['id'].toString();
        final filename = evidence['original_filename'].toString();
        final mimeType = resolveEvidenceMimeType(
          mimeType: evidence['mime_type']?.toString(),
          fileName: filename,
        );
        final downloaded = await widget.apiService.fetchEvidenceFile(
          evidenceId,
        );
        if (downloaded['success'] != true ||
            downloaded['bytes'] is! List<int>) {
          if (mounted) {
            _showMessage(
              'Could not retrieve $filename. No incident media was shared.',
            );
          }
          return;
        }
        if (mimeType.startsWith('audio/') ||
            evidence['evidence_type'] == 'audio') {
          hasAudioEvidence = true;
        }
        mediaFiles.add({
          'fileName': filename,
          'mimeType': resolveEvidenceMimeType(
            mimeType: downloaded['mime_type']?.toString() ?? mimeType,
            fileName: filename,
          ),
          'bytes': Uint8List.fromList(
            List<int>.from(downloaded['bytes'] as List),
          ),
        });
      }
    } else if (evidenceItems != null) {
      if (mounted) {
        _showMessage('Incident media list is invalid; nothing shared.');
      }
      return;
    }

    if (!hasAudioEvidence && clientEventId.isNotEmpty) {
      final localAudio = _localAudioByEventId[clientEventId];
      final bytes = await _localDatabase.getIncidentAudioBytes(clientEventId);
      if (bytes != null && bytes.isNotEmpty) {
        final fileName =
            localAudio?['file_name']?.toString() ?? 'salamasphere-$id.wav';
        mediaFiles.add({
          'fileName': fileName,
          'mimeType': localAudio?['mime_type']?.toString() ?? 'audio/wav',
          'bytes': Uint8List.fromList(bytes),
        });
      }
    }

    final hasSharedAudio = mediaFiles.any(
      (file) => file['mimeType'].toString().startsWith('audio/'),
    );
    if (!hasAudioEvidence &&
        !hasSharedAudio &&
        id != 'unknown' &&
        id != clientEventId &&
        (incident['audio_available'] == true ||
            incident['audio_url'] != null)) {
      final audio = await widget.apiService.fetchIncidentAudio(id);
      final audioBytes = audio['bytes'];
      if (audio['success'] == true &&
          audioBytes is List<int> &&
          audioBytes.isNotEmpty) {
        final mimeType = audio['mime_type']?.toString() ?? 'audio/wav';
        final extension = mimeType == 'audio/mpeg'
            ? 'mp3'
            : mimeType == 'audio/mp4'
            ? 'm4a'
            : mimeType == 'audio/aac'
            ? 'aac'
            : 'wav';
        mediaFiles.add({
          'fileName': 'salamasphere-$id.$extension',
          'mimeType': mimeType,
          'bytes': Uint8List.fromList(audioBytes),
        });
      } else {
        if (mounted) {
          _showMessage(
            audio['message']?.toString() ??
                'Could not retrieve the incident recording to share.',
          );
        }
        return;
      }
    }

    try {
      await const MethodChannel('com.salamasphere/share')
          .invokeMethod<void>('shareIncident', {
            'title': 'SalamaSphere incident $id',
            'text': text.toString(),
            'files': mediaFiles,
          });
    } on PlatformException catch (error) {
      if (mounted) _showMessage('Could not share incident: ${error.message}');
    } on MissingPluginException {
      if (mounted) {
        _showMessage('Incident sharing is unavailable on this device.');
      }
    } catch (error) {
      if (mounted) _showMessage('Could not share incident: $error');
    }
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
    return '${double.tryParse(latitude.toString()) ?? latitude}, '
        '${double.tryParse(longitude.toString()) ?? longitude}$accuracyText';
  }

  Widget _locationMapLink(Map<String, dynamic> incident, String locationText) {
    final nested = incident['location'];
    final source = nested is Map ? nested : incident;
    final uri = googleMapsUriForCoordinates(
      source['latitude'] ?? incident['latitude'],
      source['longitude'] ?? incident['longitude'],
    );
    if (uri == null) {
      return _infoRow(Icons.location_on_outlined, locationText);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 6, right: 8),
          child: Icon(
            Icons.location_on_outlined,
            size: 18,
            color: Colors.black54,
          ),
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: () async {
              final launched = await launchUrl(
                uri,
                mode: LaunchMode.externalApplication,
              );
              if (!launched && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Unable to open the location in Google Maps.',
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.map_outlined, size: 18),
            label: const Text('Open incident location in Google Maps'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _wearableSubscription?.cancel();
    _recordingStatusSubscription?.cancel();
    _audioMetadataSubscription?.cancel();
    _audioChunkSubscription?.cancel();
    _bleConnectionSubscription?.cancel();
    _bleErrorSubscription?.cancel();
    _audioPlayer.dispose();
    _connectivitySubscription?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  // =========================================================================
  // UI helpers
  // =========================================================================

  void _goToTab(int index) {
    setState(() => _selectedTab = index);
    if (index == _tabAlerts) _loadNotifications();
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  Color _threatColor(String threat) {
    switch (threat.toLowerCase()) {
      case 'critical':
      case 'high':
        return Colors.red.shade600;
      case 'medium':
        return Colors.orange.shade700;
      case 'low':
        return Colors.green.shade600;
      default:
        return Colors.blueGrey;
    }
  }

  Widget _chip(String label, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(
    String title,
    IconData icon, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _brandSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: _brand, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String text, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color ?? Colors.black45),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color ?? Colors.black87, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(IconData icon, String title, String subtitle) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        child: Column(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: _brandSoft,
              child: Icon(icon, size: 30, color: _brand),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            child: Column(
              children: [
                CircleAvatar(
                  backgroundColor: _brandSoft,
                  child: Icon(icon, color: _brand),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Wearable connection card.
  Widget _wearableCard() {
    final statusColor = _wearableConnected
        ? Colors.green.shade600
        : (_connectingWearable ? Colors.orange.shade700 : Colors.blueGrey);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: _brandSoft,
                  child: Icon(
                    _wearableConnected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth,
                    color: _brand,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'SalamaSphere Wearable',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                _chip(
                  _wearableConnected
                      ? 'Connected'
                      : (_connectingWearable ? 'Connecting' : 'Offline'),
                  statusColor,
                  icon: _wearableConnected
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _wearableMessage,
              style: const TextStyle(color: Colors.black87),
            ),
            if (_submittingSos) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: const LinearProgressIndicator(minHeight: 6),
              ),
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
                  backgroundColor: _brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
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
    final threatColor = _threatColor(threat);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Colour strip makes the threat level recognisable at a glance.
            Container(width: 6, color: threatColor),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const CircleAvatar(
                          backgroundColor: _brandSoft,
                          child: Icon(Icons.shield_outlined, color: _brand),
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
                              const SizedBox(height: 2),
                              Text(
                                'ID: $id',
                                overflow: TextOverflow.ellipsis,
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
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _chip(
                          'Threat: $threat',
                          threatColor,
                          icon: Icons.warning_amber_rounded,
                        ),
                        _chip(status, _brand, icon: Icons.sync_alt),
                      ],
                    ),
                    if (date.isNotEmpty)
                      _infoRow(Icons.schedule, _formatDate(date)),
                    _locationMapLink(incident, location),
                    _infoRow(
                      hasAudio ? Icons.audiotrack : Icons.audio_file_outlined,
                      hasAudio
                          ? 'Wearable audio attached${localAudio?['upload_status'] == 'uploaded' ? ' and uploaded' : ''}.'
                          : 'No wearable audio attached.',
                      color: hasAudio ? _brand : Colors.black45,
                    ),
                    if (incident['evidence'] is List)
                      ...((incident['evidence'] as List).whereType<Map>().map((
                        item,
                      ) {
                        final evidence = Map<String, dynamic>.from(item);
                        final filename = _field(evidence, [
                          'original_filename',
                        ], fallback: 'Evidence file');
                        final type = evidence['evidence_type']?.toString();
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            type == 'video'
                                ? Icons.videocam_outlined
                                : type == 'audio'
                                ? Icons.audiotrack
                                : Icons.attach_file,
                            color: _brand,
                          ),
                          title: Text(
                            filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${type ?? 'file'} · '
                            '${evidence['verification_status'] ?? 'uploaded'}',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) {
                              if (action == 'view') {
                                _openEvidenceFile(evidence);
                              } else {
                                _shareUploadedEvidence(evidence);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 'view', child: Text('View')),
                              PopupMenuItem(
                                value: 'share',
                                child: Text('Share with contacts'),
                              ),
                            ],
                          ),
                        );
                      })),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      children: [
                        if (hasAudio)
                          TextButton.icon(
                            onPressed: () =>
                                _showAudioAccess(incident, localAudio),
                            icon: const Icon(Icons.lock_open_outlined),
                            label: const Text('Recording'),
                          ),
                        TextButton.icon(
                          onPressed: () => _showIncidentMedia(incident),
                          icon: const Icon(Icons.video_library_outlined),
                          label: const Text('Media'),
                        ),
                        TextButton.icon(
                          onPressed: () => _shareIncident(incident),
                          icon: const Icon(Icons.share_outlined),
                          label: const Text('Share'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Incident list with loading / error / empty states. [limit] is used on
  // the Home tab to show only the latest few.
  List<Widget> _incidentSection({int? limit}) {
    if (_loading) {
      return const [
        Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        ),
      ];
    }
    if (!_connected) {
      return [
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                const Icon(Icons.cloud_off, size: 38, color: Colors.orange),
                const SizedBox(height: 8),
                Text(_message, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _loadIncidents,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (_incidents.isEmpty) {
      return [
        _emptyState(
          Icons.inbox_outlined,
          'No incidents recorded yet',
          'Incidents will appear here when they have been created and '
              'linked to your account.',
        ),
      ];
    }
    final shown = limit == null ? _incidents : _incidents.take(limit).toList();
    return shown.map(_incidentCard).toList();
  }

  // =========================================================================
  // Tabs
  // =========================================================================

  Widget _homeTab() {
    return RefreshIndicator(
      onRefresh: _loadIncidents,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_brand, _brandDark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
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
                  '${_greeting()}, ${widget.username}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Your safety space. Access your incident history '
                  'and monitor your connection.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _headerPill(
                      _connected ? Icons.cloud_done : Icons.cloud_off,
                      _connected ? 'Backend connected' : 'Backend unavailable',
                    ),
                    _headerPill(
                      _wearableConnected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth_disabled,
                      _wearableConnected ? 'Wearable on' : 'Wearable off',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Wearable connection', Icons.bluetooth),
          _wearableCard(),
          const SizedBox(height: 20),
          _sectionTitle('Quick actions', Icons.bolt),
          Row(
            children: [
              _quickAction(
                icon: Icons.upload_file,
                label: 'Share\nevidence',
                onTap: () => _goToTab(_tabEvidence),
              ),
              const SizedBox(width: 10),
              _quickAction(
                icon: Icons.people_outline,
                label: 'Trusted\ncontacts',
                onTap: _manageTrustedContacts,
              ),
              const SizedBox(width: 10),
              _quickAction(
                icon: Icons.history,
                label: 'My\nincidents',
                onTap: () => _goToTab(_tabIncidents),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _sectionTitle(
            'Recent incidents',
            Icons.history,
            actionLabel: _incidents.length > 3 ? 'See all' : null,
            onAction: () => _goToTab(_tabIncidents),
          ),
          if (!_loading && _connected)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _message,
                style: const TextStyle(color: Colors.black54),
              ),
            ),
          ..._incidentSection(limit: 3),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'For immediate danger, contact local emergency '
                    'services or a trusted person. This development '
                    'version does not yet guarantee SOS delivery.',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerPill(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _incidentsTab() {
    return RefreshIndicator(
      onRefresh: _loadIncidents,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Your incidents', Icons.history),
          if (!_loading && _connected)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _message,
                style: const TextStyle(color: Colors.black54),
              ),
            ),
          ..._incidentSection(),
        ],
      ),
    );
  }

  Widget _evidenceTab() {
    Widget step(IconData icon, String title, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: _brandSoft,
            child: Icon(icon, color: _brand, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(text, style: const TextStyle(color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle('Share evidence', Icons.upload_file),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Upload audio or video from your phone, add a message, '
                  'and choose who should receive it. The submission is '
                  'stored as an incident and protected in the evidence vault.',
                  style: TextStyle(color: Colors.black87),
                ),
                const SizedBox(height: 18),
                step(
                  Icons.attach_file,
                  '1. Choose a file',
                  'Audio or video from your phone.',
                ),
                step(
                  Icons.edit_note,
                  '2. Add a message',
                  'Describe what happened in your own words.',
                ),
                step(
                  Icons.send_outlined,
                  '3. Pick who receives it',
                  'Authorities, trusted contacts, or both.',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _brand,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _openEvidenceComposer,
            icon: const Icon(Icons.add),
            label: const Text('Choose audio or video'),
          ),
        ),
      ],
    );
  }

  Widget _alertsTab() {
    return RefreshIndicator(
      onRefresh: _loadNotifications,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Notifications', Icons.notifications_outlined),
          if (_loadingNotifications)
            const Center(child: CircularProgressIndicator())
          else if (_notificationsList.isEmpty)
            _emptyState(
              Icons.notifications_none,
              'No notifications yet',
              'Updates about your shared incidents will show up here.',
            )
          else
            ..._notificationsList.map(
              (item) => Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: _brandSoft,
                    child: Icon(Icons.notifications_active, color: _brand),
                  ),
                  title: Text(
                    item is Map
                        ? (item['title'] ??
                                  item['message'] ??
                                  'New shared information')
                              .toString()
                        : 'New shared information',
                  ),
                  subtitle: Text(
                    item is Map
                        ? (item['created_at'] ?? item['status'] ?? '')
                              .toString()
                        : '',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _contactsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionTitle('Trusted contacts', Icons.people_outline),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Padding(
            padding: EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.favorite_border, color: _brand),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Manage the people who can receive your shared safety '
                    'information. They get privacy-conscious SOS SMS alerts.',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _brand,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _manageTrustedContacts,
            icon: const Icon(Icons.manage_accounts),
            label: const Text('Manage trusted contacts'),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _addTrustedContact,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Add a new contact'),
          ),
        ),
      ],
    );
  }

  // Profile moved out of the bottom bar (which had 6 crowded items) into a
  // sheet opened from the avatar in the app bar.
  void _showProfileSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 34,
                backgroundColor: _brandSoft,
                child: Text(
                  widget.username.isEmpty
                      ? '?'
                      : widget.username[0].toUpperCase(),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: _brand,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.username,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Text(
                'Victim account',
                style: TextStyle(color: Colors.black54),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.people_outline, color: _brand),
                title: const Text('Trusted contacts'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _goToTab(_tabContacts);
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text(
                  'Log out',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _confirmLogout();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_selectedTab) {
      case _tabIncidents:
        return _incidentsTab();
      case _tabEvidence:
        return _evidenceTab();
      case _tabAlerts:
        return _alertsTab();
      case _tabContacts:
        return _contactsTab();
      case _tabHome:
      default:
        return _homeTab();
    }
  }

  static const List<String> _titles = [
    'SalamaSphere',
    'My incidents',
    'Share evidence',
    'Notifications',
    'Trusted contacts',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBg,
      appBar: AppBar(
        title: Text(_titles[_selectedTab]),
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh incidents',
            onPressed: _loading ? null : _loadIncidents,
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: 'Profile',
              onPressed: _showProfileSheet,
              icon: CircleAvatar(
                radius: 15,
                backgroundColor: Colors.white,
                child: Text(
                  widget.username.isEmpty
                      ? '?'
                      : widget.username[0].toUpperCase(),
                  style: const TextStyle(
                    color: _brand,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: KeyedSubtree(
          key: ValueKey<int>(_selectedTab),
          child: _buildBody(),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        backgroundColor: Colors.white,
        indicatorColor: _brandSoft,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: _goToTab,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home, color: _brand),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _incidents.isNotEmpty,
              label: Text('${_incidents.length}'),
              child: const Icon(Icons.history),
            ),
            selectedIcon: const Icon(Icons.history, color: _brand),
            label: 'Incidents',
          ),
          const NavigationDestination(
            icon: Icon(Icons.upload_file_outlined),
            selectedIcon: Icon(Icons.upload_file, color: _brand),
            label: 'Evidence',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _notificationsList.isNotEmpty,
              label: Text('${_notificationsList.length}'),
              child: const Icon(Icons.notifications_outlined),
            ),
            selectedIcon: const Icon(Icons.notifications, color: _brand),
            label: 'Alerts',
          ),
          const NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people, color: _brand),
            label: 'Trusted',
          ),
        ],
      ),
    );
  }
}

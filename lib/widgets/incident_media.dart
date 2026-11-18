import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../services/api_service.dart';

String resolveEvidenceMimeType({String? mimeType, required String? fileName}) {
  if (mimeType != null &&
      mimeType.isNotEmpty &&
      mimeType != 'application/octet-stream') {
    return mimeType;
  }

  final extension = fileName?.split('.').last.toLowerCase();
  const knownTypes = {
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'amr': 'audio/amr',
    'wav': 'audio/wav',
  };
  return knownTypes[extension] ?? mimeType ?? 'application/octet-stream';
}

class IncidentEvidenceList extends StatefulWidget {
  final ApiService apiService;
  final String incidentId;

  const IncidentEvidenceList({
    super.key,
    required this.apiService,
    required this.incidentId,
  });

  @override
  State<IncidentEvidenceList> createState() => _IncidentEvidenceListState();
}

class _IncidentEvidenceListState extends State<IncidentEvidenceList> {
  late final Future<List<Map<String, dynamic>>> _evidenceFuture;
  final Set<String> _openingEvidenceIds = <String>{};

  @override
  void initState() {
    super.initState();
    _evidenceFuture = _loadEvidence();
  }

  Future<List<Map<String, dynamic>>> _loadEvidence() async {
    final response = await widget.apiService.fetchIncidentEvidence(
      widget.incidentId,
    );
    if (response['success'] != true) {
      throw StateError(
        response['message']?.toString() ?? 'Could not load incident media.',
      );
    }

    dynamic records = response['data'];
    while (records is Map) {
      if (records['results'] is List) {
        records = records['results'];
      } else if (records['evidence'] is List) {
        records = records['evidence'];
      } else if (records['data'] is List || records['data'] is Map) {
        records = records['data'];
      } else {
        break;
      }
    }
    if (records is! List) {
      throw const FormatException('The incident media response is invalid.');
    }
    return records
        .whereType<Map>()
        .where((item) => item.keys.every((key) => key is String))
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> _openEvidence(Map<String, dynamic> evidence) async {
    final id = evidence['id']?.toString();
    if (id == null || id.isEmpty || !_openingEvidenceIds.add(id)) return;
    setState(() {});
    final response = await widget.apiService.fetchEvidenceFile(id);
    if (!mounted) return;
    setState(() => _openingEvidenceIds.remove(id));

    final bytes = response['bytes'];
    if (response['success'] != true || bytes is! List<int> || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            response['message']?.toString() ?? 'Could not load incident media.',
          ),
        ),
      );
      return;
    }

    final fileName =
        evidence['original_filename']?.toString() ?? 'Incident media';
    final mimeType = resolveEvidenceMimeType(
      mimeType:
          response['mime_type']?.toString() ??
          evidence['mime_type']?.toString(),
      fileName: fileName,
    );
    await showEvidenceMediaDialog(
      context,
      fileName: fileName,
      mimeType: mimeType,
      bytes: bytes,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _evidenceFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const ListTile(
            leading: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('Loading incident media...'),
          );
        }
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(Icons.error_outline),
            title: const Text('Could not load incident media'),
            subtitle: Text('${snapshot.error}'),
          );
        }

        final evidence = snapshot.data ?? const <Map<String, dynamic>>[];
        if (evidence.isEmpty) {
          return const ListTile(
            leading: Icon(Icons.perm_media_outlined),
            title: Text('No uploaded media for this incident.'),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Incident media',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ...evidence.map((item) {
              final id = item['id']?.toString() ?? '';
              final mimeType = resolveEvidenceMimeType(
                mimeType: item['mime_type']?.toString(),
                fileName: item['original_filename']?.toString(),
              );
              final isVideo =
                  mimeType.startsWith('video/') ||
                  item['evidence_type'] == 'video';
              final isAudio =
                  mimeType.startsWith('audio/') ||
                  item['evidence_type'] == 'audio';
              return Column(
                children: [
                  ListTile(
                    leading: Icon(
                      isVideo
                          ? Icons.video_file_outlined
                          : isAudio
                          ? Icons.audio_file_outlined
                          : Icons.attach_file,
                    ),
                    title: Text(
                      item['original_filename']?.toString() ?? 'Incident media',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      isVideo
                          ? 'Video'
                          : isAudio
                          ? 'Audio'
                          : 'File',
                    ),
                    trailing: _openingEvidenceIds.contains(id)
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_circle_outline),
                    onTap: id.isEmpty || _openingEvidenceIds.contains(id)
                        ? null
                        : () => _openEvidence(item),
                  ),
                  if (isAudio && id.isNotEmpty)
                    AudioTranscriptionReview(
                      apiService: widget.apiService,
                      evidenceId: id,
                    ),
                ],
              );
            }),
          ],
        );
      },
    );
  }
}

class AudioTranscriptionReview extends StatefulWidget {
  final ApiService apiService;
  final String evidenceId;

  const AudioTranscriptionReview({
    super.key,
    required this.apiService,
    required this.evidenceId,
  });

  @override
  State<AudioTranscriptionReview> createState() =>
      _AudioTranscriptionReviewState();
}

class _AudioTranscriptionReviewState extends State<AudioTranscriptionReview> {
  final Map<String, TextEditingController> _controllers = {};
  List<Map<String, dynamic>> _transcripts = [];
  String _language = 'auto';
  String? _error;
  bool _loading = true;
  bool _transcribing = false;
  final Set<String> _saving = <String>{};

  @override
  void initState() {
    super.initState();
    _loadTranscripts();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadTranscripts() async {
    final response = await widget.apiService.fetchEvidenceTranscripts(
      widget.evidenceId,
    );
    if (!mounted) return;
    if (response['success'] != true) {
      setState(() {
        _loading = false;
        _error =
            response['message']?.toString() ??
            'Could not load transcript history.';
      });
      return;
    }
    final data = response['data'];
    final rows = data is List ? data : const [];
    setState(() {
      _transcripts = rows
          .whereType<Map>()
          .where((row) => row.keys.every((key) => key is String))
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      _loading = false;
      _error = null;
    });
  }

  String _errorMessage(Map<String, dynamic> response) {
    final data = response['data'];
    final code = data is Map ? data['error_code']?.toString() : null;
    return switch (code) {
      'provider_timeout' => 'Speech recognition timed out. Try again later.',
      'provider_request_failed' => 'Speech recognition rejected the request. Check the recording and try again.',
      'no_speech_recognized' => 'No speech was recognized in this recording.',
      'evidence_integrity_failed' =>
        'The audio failed its integrity check and was not transcribed.',
      'evidence_unavailable' => 'The original audio is unavailable.',
      _ =>
        response['message']?.toString() ??
            (data is Map ? data['error']?.toString() : null) ??
            'Could not transcribe this recording.',
    };
  }

  Future<void> _transcribe() async {
    setState(() {
      _transcribing = true;
      _error = null;
    });
    final response = await widget.apiService.transcribeEvidence(
      widget.evidenceId,
      language: _language,
    );
    if (!mounted) return;
    if (response['success'] != true) {
      setState(() {
        _transcribing = false;
        _error = _errorMessage(response);
      });
      await _loadTranscripts();
      if (mounted) setState(() => _error = _errorMessage(response));
      return;
    }
    setState(() => _transcribing = false);
    await _loadTranscripts();
  }

  TextEditingController _controllerFor(Map<String, dynamic> transcript) {
    final id = transcript['transcript_id']?.toString() ?? '';
    return _controllers.putIfAbsent(
      id,
      () => TextEditingController(
        text: (transcript['reviewed_transcript'] as String?)?.isNotEmpty == true
            ? transcript['reviewed_transcript'] as String
            : transcript['transcript']?.toString() ?? '',
      ),
    );
  }

  Future<void> _saveCorrection(Map<String, dynamic> transcript) async {
    final id = transcript['transcript_id']?.toString() ?? '';
    final controller = _controllerFor(transcript);
    if (id.isEmpty || controller.text.trim().isEmpty || !_saving.add(id)) {
      return;
    }
    setState(() {});
    final response = await widget.apiService.reviewEvidenceTranscript(
      transcriptId: id,
      correctedText: controller.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _saving.remove(id);
      if (response['success'] != true) {
        _error =
            response['message']?.toString() ??
            'Could not save the human correction.';
      } else {
        _error = null;
      }
    });
    if (response['success'] == true) await _loadTranscripts();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Speech-to-text (human review required)',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              DropdownButton<String>(
                value: _language,
                onChanged: _transcribing
                    ? null
                    : (value) => setState(() => _language = value ?? 'auto'),
                items: const [
                  DropdownMenuItem(value: 'auto', child: Text('Auto detect')),
                  DropdownMenuItem(value: 'sw', child: Text('Kiswahili')),
                  DropdownMenuItem(value: 'en', child: Text('English')),
                ],
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _transcribing ? null : _transcribe,
              icon: _transcribing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.graphic_eq),
              label: Text(_transcribing ? 'Transcribing…' : 'Transcribe audio'),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_loading) const LinearProgressIndicator(),
          for (final transcript in _transcripts) _transcriptCard(transcript),
        ],
      ),
    );
  }

  Widget _transcriptCard(Map<String, dynamic> transcript) {
    final id = transcript['transcript_id']?.toString() ?? '';
    final status = transcript['status']?.toString() ?? 'unknown';
    final language = transcript['language']?.toString() ?? 'not reported';
    final history = transcript['history'] is List
        ? transcript['history'] as List
        : const [];
    if (status != 'completed') {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Transcription $status'),
        subtitle: Text(transcript['error_code']?.toString() ?? ''),
      );
    }
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Machine transcript · $language',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            SelectableText(transcript['transcript']?.toString() ?? ''),
            const SizedBox(height: 12),
            const Text(
              'Human correction',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _controllerFor(transcript),
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Review and correct the transcript',
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _saving.contains(id)
                    ? null
                    : () => _saveCorrection(transcript),
                icon: _saving.contains(id)
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Save correction'),
              ),
            ),
            if (history.isNotEmpty) ...[
              const Divider(),
              const Text(
                'Correction history',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final revision in history.whereType<Map>())
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SelectableText(revision['text']?.toString() ?? ''),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> showEvidenceMediaDialog(
  BuildContext context, {
  required String fileName,
  required String mimeType,
  required List<int> bytes,
}) async {
  if (!mimeType.startsWith('video/') && !mimeType.startsWith('audio/')) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This media format cannot be played.')),
    );
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: EvidenceMediaPreview(
        fileName: fileName,
        mimeType: mimeType,
        bytes: bytes,
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

class EvidenceMediaPreview extends StatefulWidget {
  final String fileName;
  final String mimeType;
  final List<int> bytes;

  const EvidenceMediaPreview({
    super.key,
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });

  @override
  State<EvidenceMediaPreview> createState() => _EvidenceMediaPreviewState();
}

class _EvidenceMediaPreviewState extends State<EvidenceMediaPreview> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  VideoPlayerController? _videoController;
  File? _temporaryVideo;
  StreamSubscription<void>? _audioCompleteSubscription;
  bool _audioPlaying = false;
  String? _error;

  bool get _isVideo => widget.mimeType.startsWith('video/');

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      unawaited(_initializeVideo());
    } else {
      _audioCompleteSubscription = _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _audioPlaying = false);
      });
    }
  }

  Future<void> _initializeVideo() async {
    VideoPlayerController? controller;
    try {
      final directory = await getTemporaryDirectory();
      final safeName = path
          .basename(widget.fileName)
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final file = File(
        path.join(
          directory.path,
          'salamasphere-preview-${DateTime.now().microsecondsSinceEpoch}-$safeName',
        ),
      );
      await file.writeAsBytes(widget.bytes, flush: true);
      _temporaryVideo = file;
      controller = VideoPlayerController.file(file);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        if (await file.exists()) await file.delete();
        return;
      }
      setState(() => _videoController = controller);
    } catch (error) {
      if (controller != null) await controller.dispose();
      if (mounted) setState(() => _error = 'Could not play video: $error');
    }
  }

  Future<void> _togglePlayback() async {
    try {
      if (_isVideo) {
        final controller = _videoController;
        if (controller == null) return;
        if (controller.value.isPlaying) {
          await controller.pause();
        } else {
          await controller.play();
        }
        if (mounted) setState(() {});
      } else if (_audioPlaying) {
        await _audioPlayer.pause();
        if (mounted) setState(() => _audioPlaying = false);
      } else {
        await _audioPlayer.play(BytesSource(Uint8List.fromList(widget.bytes)));
        if (mounted) setState(() => _audioPlaying = true);
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not play media: $error');
    }
  }

  @override
  void dispose() {
    _audioCompleteSubscription?.cancel();
    unawaited(_audioPlayer.dispose());
    final controller = _videoController;
    final file = _temporaryVideo;
    if (controller != null) {
      unawaited(
        controller.dispose().then((_) async {
          if (file != null && await file.exists()) await file.delete();
        }),
      );
    } else if (file != null) {
      unawaited(file.delete());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Text(_error!),
      );
    }
    if (_isVideo) {
      final controller = _videoController;
      if (controller == null || !controller.value.isInitialized) {
        return const SizedBox(
          width: 320,
          height: 180,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
            Row(
              children: [
                IconButton(
                  onPressed: _togglePlayback,
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    controller,
                    allowScrubbing: true,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return SizedBox(
      width: 320,
      child: Row(
        children: [
          IconButton(
            onPressed: _togglePlayback,
            icon: Icon(_audioPlaying ? Icons.pause : Icons.play_arrow),
          ),
          Expanded(
            child: Text(_audioPlaying ? 'Playing audio' : 'Audio ready'),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../models/authority_verification_document.dart';
import '../services/api_service.dart';

class AdminVerificationScreen extends StatefulWidget {
  final ApiService apiService;

  const AdminVerificationScreen({
    super.key,
    required this.apiService,
  });

  @override
  State<AdminVerificationScreen> createState() =>
      _AdminVerificationScreenState();
}

class _AdminVerificationScreenState
    extends State<AdminVerificationScreen> {
  bool _isLoading = false;
  String? _errorMessage;

  List<AuthorityVerificationDocument> _documents = [];

  @override
  void initState() {
    super.initState();
    _loadDocuments();
  }

  Future<void> _loadDocuments() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result =
        await widget.apiService.fetchPendingAuthorityDocuments();

    if (!mounted) return;

    setState(() {
      _isLoading = false;

      if (result['success'] == true) {
        _documents =
            result['documents'] as List<AuthorityVerificationDocument>;
      } else {
        _errorMessage =
            result['message']?.toString() ??
            'Unable to load verification documents.';
      }
    });
  }

  Future<void> _reviewDocument(
    AuthorityVerificationDocument document,
    String decision,
  ) async {
    final reasonController = TextEditingController();

    if (decision == 'rejected') {
      final reason = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Reject verification document'),
            content: TextField(
              controller: reasonController,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason for rejection',
                hintText: 'Explain why this document is being rejected',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final reason = reasonController.text.trim();

                  if (reason.isEmpty) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'A rejection reason is required.',
                        ),
                      ),
                    );
                    return;
                  }

                  Navigator.of(dialogContext).pop(reason);
                },
                child: const Text('Continue'),
              ),
            ],
          );
        },
      );

      reasonController.dispose();

      if (reason == null || reason.trim().isEmpty) return;

      await _submitReview(
        document,
        decision,
        reason.trim(),
      );

      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Accept verification document'),
          content: Text(
            'Accept the ${_formatDocumentType(document.documentType)} '
            'submitted by ${document.username}?',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(true),
              child: const Text('Accept document'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    await _submitReview(document, decision, '');
  }

  Future<void> _submitReview(
    AuthorityVerificationDocument document,
    String decision,
    String reason,
  ) async {
    final result = await widget.apiService.reviewAuthorityDocument(
      documentId: document.id,
      decision: decision,
      reason: reason,
    );

    if (!mounted) return;

    final success = result['success'] == true;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result['message']?.toString() ??
              'The review could not be completed.',
        ),
      ),
    );

    if (success) {
      await _loadDocuments();
    }
  }

  String _formatDocumentType(String value) {
    return value
        .split('_')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  String _formatDate(DateTime date) {
    final localDate = date.toLocal();

    final day = localDate.day.toString().padLeft(2, '0');
    final month = localDate.month.toString().padLeft(2, '0');
    final year = localDate.year.toString();

    final hour = localDate.hour.toString().padLeft(2, '0');
    final minute = localDate.minute.toString().padLeft(2, '0');

    return '$day/$month/$year at $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Authority Verification'),
        actions: [
          IconButton(
            tooltip: 'Refresh documents',
            onPressed: _isLoading ? null : _loadDocuments,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDocuments,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _documents.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_errorMessage != null && _documents.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 100),
          const Icon(
            Icons.cloud_off,
            size: 56,
          ),
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.icon(
              onPressed: _loadDocuments,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ),
        ],
      );
    }

    if (_documents.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(24),
        children: const [
          SizedBox(height: 100),
          Icon(
            Icons.verified_user_outlined,
            size: 64,
          ),
          SizedBox(height: 16),
          Text(
            'No pending verification documents.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'New submissions will appear here when available.',
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(
                  Icons.pending_actions,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pending verification',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 17,
                        ),
                      ),
                      Text(
                        '${_documents.length} document(s) awaiting review',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final document in _documents)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const CircleAvatar(
                        child: Icon(Icons.badge_outlined),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              document.username.isEmpty
                                  ? 'Authority #${document.authorityId}'
                                  : document.username,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              document.email.isEmpty
                                  ? 'Email not provided'
                                  : document.email,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  _detailRow(
                    'Document type',
                    _formatDocumentType(document.documentType),
                  ),
                  const SizedBox(height: 8),
                  _detailRow(
                    'Status',
                    _formatDocumentType(document.reviewStatus),
                  ),
                  const SizedBox(height: 8),
                  _detailRow(
                    'Submitted',
                    _formatDate(document.submittedAt),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _reviewDocument(
                          document,
                          'accepted',
                        ),
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Accept'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _reviewDocument(
                          document,
                          'rejected',
                        ),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Reject'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 105,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(value),
        ),
      ],
    );
  }
}

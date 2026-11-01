import 'package:flutter/material.dart';

import '../services/api_service.dart';

class AdminAccountManagementScreen extends StatefulWidget {
  final ApiService apiService;

  const AdminAccountManagementScreen({super.key, required this.apiService});

  @override
  State<AdminAccountManagementScreen> createState() =>
      _AdminAccountManagementScreenState();
}

class _AdminAccountManagementScreenState
    extends State<AdminAccountManagementScreen> {
  List<Map<String, dynamic>> _accounts = [];
  bool _isLoading = true;
  String? _errorMessage;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await widget.apiService.fetchAuthorityAccounts();

    if (!mounted) return;

    setState(() {
      _isLoading = false;

      if (result['success'] == true) {
        _accounts = List<Map<String, dynamic>>.from(result['accounts'] as List);
      } else {
        _errorMessage =
            result['message']?.toString() ??
            'Could not load authority accounts.';
      }
    });
  }

  Future<String?> _askReason({
    required String title,
    required String explanation,
  }) async {
    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(explanation),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Enter the reason...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    controller.dispose();
    return result;
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );

    return result == true;
  }

  Future<void> _performAction(
    Map<String, dynamic> account,
    String action,
  ) async {
    final userId = account['id'];

    if (userId is! int) {
      _showMessage('Invalid authority account ID.');
      return;
    }

    String reason = '';

    if (action == 'reject') {
      final enteredReason = await _askReason(
        title: 'Reject authority application',
        explanation: 'Provide a reason for rejecting this application.',
      );

      if (enteredReason == null) return;

      if (enteredReason.trim().isEmpty) {
        _showMessage('A rejection reason is required.');
        return;
      }

      reason = enteredReason;
    } else if (action == 'suspend') {
      final enteredReason = await _askReason(
        title: 'Suspend authority account',
        explanation: 'Explain why this approved account should be suspended.',
      );

      if (enteredReason == null) return;
      reason = enteredReason;
    } else {
      final isApproval = action == 'approve';
      final confirmed = await _confirmAction(
        title: isApproval
            ? 'Approve authority application'
            : 'Reactivate authority account',
        message: isApproval
            ? 'Confirm that the submitted verification documents have '
                  'been reviewed and this authority may be approved.'
            : 'Allow this approved authority account to become active again?',
        confirmLabel: isApproval ? 'Approve' : 'Reactivate',
      );

      if (!confirmed) return;
    }

    Map<String, dynamic> result;

    if (action == 'approve' || action == 'reject') {
      result = await widget.apiService.reviewAuthorityApplication(
        userId: userId,
        decision: action,
        reason: reason,
      );
    } else {
      result = await widget.apiService.updateAuthorityAccountStatus(
        userId: userId,
        action: action,
        reason: reason,
      );
    }

    if (!mounted) return;

    _showMessage(result['message']?.toString() ?? 'Request completed.');

    if (result['success'] == true) {
      await _loadAccounts();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Color _statusColor(String status, bool isActive) {
    if (status == 'approved' && isActive) return Colors.green;
    if (status == 'pending') return Colors.orange;
    if (status == 'rejected' || !isActive) return Colors.red;
    return Colors.blueGrey;
  }

  String _statusLabel(String status, bool isActive) {
    if (status == 'approved' && !isActive) {
      return 'Approved · Suspended';
    }

    switch (status) {
      case 'approved':
        return 'Approved · Active';
      case 'pending':
        return 'Pending verification';
      case 'rejected':
        return 'Application rejected';
      default:
        return status.isEmpty ? 'Unknown status' : status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchQuery.trim().toLowerCase();

    final filteredAccounts = _accounts.where((account) {
      final username = (account['username'] ?? '').toString().toLowerCase();
      final email = (account['email'] ?? '').toString().toLowerCase();
      final phone = (account['phone_number'] ?? '').toString().toLowerCase();

      return username.contains(query) ||
          email.contains(query) ||
          phone.contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Authority Account Management'),
        actions: [
          IconButton(
            onPressed: _isLoading ? null : _loadAccounts,
            tooltip: 'Refresh accounts',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
              decoration: const InputDecoration(
                labelText: 'Search authority accounts',
                hintText: 'Username, email, or phone number',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_errorMessage!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _loadAccounts,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  )
                : filteredAccounts.isEmpty
                ? const Center(
                    child: Text('No matching authority accounts found.'),
                  )
                : RefreshIndicator(
                    onRefresh: _loadAccounts,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: filteredAccounts.length,
                      itemBuilder: (context, index) {
                        final account = filteredAccounts[index];

                        final username = (account['username'] ?? 'Unknown')
                            .toString();
                        final email = (account['email'] ?? '').toString();
                        final phone = (account['phone_number'] ?? '')
                            .toString();
                        final status = (account['authority_status'] ?? '')
                            .toString();
                        final isActive = account['is_active'] == true;

                        final color = _statusColor(status, isActive);

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
                                      child: Text(
                                        username.isEmpty
                                            ? '?'
                                            : username[0].toUpperCase(),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            username,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                          if (email.isNotEmpty) Text(email),
                                          if (phone.isNotEmpty)
                                            Text('Phone: $phone'),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    _statusLabel(status, isActive),
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (status == 'pending') ...[
                                      FilledButton.icon(
                                        onPressed: () =>
                                            _performAction(account, 'approve'),
                                        icon: const Icon(Icons.check),
                                        label: const Text('Approve'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () =>
                                            _performAction(account, 'reject'),
                                        icon: const Icon(Icons.close),
                                        label: const Text('Reject'),
                                      ),
                                    ],
                                    if (status == 'approved' && isActive)
                                      OutlinedButton.icon(
                                        onPressed: () =>
                                            _performAction(account, 'suspend'),
                                        icon: const Icon(Icons.block),
                                        label: const Text('Suspend'),
                                      ),
                                    if (status == 'approved' && !isActive)
                                      FilledButton.icon(
                                        onPressed: () => _performAction(
                                          account,
                                          'reactivate',
                                        ),
                                        icon: const Icon(Icons.check_circle),
                                        label: const Text('Reactivate'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
